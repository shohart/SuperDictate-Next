"""The local LLM host process, and the OpenAI-compatible client for it.

Builds ship ``superdictate-llm-host.exe``, the hand-written C++ host the
macOS build spawns (``swift/Sources/llama_cpp_host/bridge/``, built with
CPU and Vulkan backends by ``tools/build-engines.ps1``); llama.cpp's own
``llama-server`` (``tools/fetch-llama.ps1``, ``engines\\llama``) is the
fallback when a build carries only that. Either one loads one GGUF model
(optionally with a LoRA adapter) and serves ``/health`` plus
``/v1/chat/completions`` over loopback HTTP — deliberately indistinguishable
from a real OpenAI-compatible server, so the same client code below serves
both it and a user-supplied endpoint.

Two Windows-specific things this module has to get right, both learned the
hard way:

* **Proxies.** ``urllib`` picks up the system WinINET proxy and will route
  even ``127.0.0.1`` through it, which answers 503 for a loopback host it
  cannot reach. So local endpoints -- loopback, the private LAN ranges
  people actually run LM Studio and Ollama on, and mDNS ``.local`` names --
  never use a proxy. Remote internet endpoints do use the system one unless
  the user clears "Use the system proxy" in Settings
  (``llm_use_system_proxy_v1``). Sending remote endpoints direct was a bug:
  where the provider is only reachable through the proxy (OpenRouter behind
  a local XRay client here), every rewrite failed with the network's own
  HTTP 403.
* **Orphans.** The host holds gigabytes of model memory, so it must not
  outlive the app. It watches its parent itself, but that is best-effort;
  this module also assigns it to a job object that kills it when the app's
  handle closes, which survives even a hard kill of the app.
"""

from __future__ import annotations

import ipaddress
import json
import os
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit
from dataclasses import dataclass, field
from typing import Optional, Sequence

from .. import paths
from ..logging_setup import get as get_logger
from .prompts import Message

log = get_logger("llm.host")

HEALTH_TIMEOUT_SECONDS = 60.0
REQUEST_TIMEOUT_SECONDS = 180.0

# One opener for the whole module: build_opener with an empty ProxyHandler
# disables proxy lookup entirely. See this module's docstring.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
#: For remote endpoints: urllib's default handlers, i.e. the system proxy
#: (WinINET settings on Windows, *_PROXY variables elsewhere) and its bypass
#: list.
_REMOTE_OPENER = urllib.request.build_opener()

_LOCAL_HOST_NAMES = {"localhost", "::1", "0.0.0.0"}
# Explicit LAN ranges rather than ``ipaddress.is_private``: the latter also
# calls documentation and benchmark ranges private, and those are not
# reachable on the user's own network. CGNAT (100.64/10) is included
# because some ISPs and Tailscale-style overlays hand it out.
_LOCAL_NETWORKS_V4 = tuple(ipaddress.ip_network(net) for net in (
    "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
    "169.254.0.0/16", "100.64.0.0/10", "0.0.0.0/32",
))
_LOCAL_NETWORKS_V6 = tuple(ipaddress.ip_network(net) for net in (
    "::1/128", "fc00::/7", "fe80::/10", "::/128",
))


def _is_local_network_host(host: str) -> bool:
    """Whether ``host`` is reachable on this machine or its own LAN.

    Covers loopback, the IPv4 private ranges (10/8, 172.16/12,
    192.168/16), link-local and CGNAT addresses, IPv6 loopback/ULA/
    link-local, and mDNS ``.local`` names. A public name is deliberately
    not resolved here: DNS may itself only be reachable through the proxy,
    and resolving on every request would add a lookup to the dictation
    path. Literal LAN addresses and ``.local`` names are what local LLM
    servers are configured with.
    """
    host = (host or "").strip().lower().rstrip(".")
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    if not host:
        return False
    if host in _LOCAL_HOST_NAMES or host.endswith(".local") \
            or host.endswith(".localhost"):
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    if isinstance(address, ipaddress.IPv4Address):
        return any(address in network for network in _LOCAL_NETWORKS_V4)
    return any(address in network for network in _LOCAL_NETWORKS_V6)


def _opener_for(url: str, use_system_proxy: bool = True):
    """Pick the opener for one request.

    Local-network endpoints always go direct. Internet endpoints use the
    system proxy when the user allows it, and go direct otherwise.
    """
    host = urlsplit(url).hostname or ""
    if not use_system_proxy or _is_local_network_host(host):
        return _OPENER
    return _REMOTE_OPENER


class LLMHostError(Exception):
    """The host could not be started, or did not become ready."""


def _free_loopback_port() -> int:
    """Ask the OS for a free port, then hand it to the host.

    Racy in principle — the port is released before the host binds it — and
    the same approach the macOS build uses. A collision surfaces as the host
    exiting immediately, which the readiness wait already reports.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def llama_server_executable() -> "os.PathLike[str]":
    """llama.cpp's own server, Vulkan build (tools/fetch-llama.ps1)."""
    return paths.resource_path("engines", "llama", "llama-server.exe")


def own_host_executable() -> "os.PathLike[str]":
    """The hand-written host shared with macOS (tools/build-engines.ps1)."""
    return paths.resource_path("engines", "superdictate-llm-host.exe")


def host_executable() -> "os.PathLike[str]":
    """Where the bundled host binary lives.

    Our own host first: it keeps a snapshot of the shared prompt prefix (the
    correction system prompt and its examples, ~276 of ~295 tokens) and
    decodes only the sentence, on the CPU and the GPU alike. llama-server
    (tools/fetch-llama.ps1) is the fallback when a build carries only it.
    """
    own = own_host_executable()
    if os.path.isfile(own):
        return own
    return llama_server_executable()


#: Threads for the CPU path of our host. llama.cpp's own threadpool (this
#: build has no OpenMP) waits at a barrier after every op for the slowest
#: thread. On a Core Ultra 5 225H, all 14 cores (4 P, 8 E, 2 low-power E)
#: turned a 0.3 s correction into minutes as soon as other programs used the
#: CPU, while 8 and 12 threads took 0.22-0.29 s per sentence. Leaving cores
#: free is what keeps the barrier from stalling: physical cores minus two,
#: like the speech threads, and no more than 8 -- the model is 0.8B and
#: memory-bound beyond that.
LLM_MAX_THREADS = 8


def llm_thread_count(physical_cores: Optional[int] = None) -> int:
    override = os.environ.get("SUPERDICTATE_LLM_THREADS", "")
    if override.isdigit() and 1 <= int(override) <= 64:
        return int(override)
    if physical_cores is None:
        from ..onnx_host import physical_core_count

        physical_cores = physical_core_count()
    return max(2, min(LLM_MAX_THREADS, physical_cores - 2))


def bundled_host_available() -> bool:
    """Whether this build ships a local host at all. Without one,
    post-processing runs through a user-supplied OpenAI-compatible endpoint."""
    return os.path.isfile(host_executable())


def host_command(executable: str, spec: "HostSpec", port: int) -> tuple[list[str], Optional[str],
                                                                          dict[str, str]]:
    """``(argv, cwd, extra environment)`` for one host process.

    llama-server takes the macOS host's flags with three differences, all
    measured on the target (Core Ultra 5 225H, Arc 130T, driver
    32.0.101.6554) with the VoiceScribe correction set:

    * A LoRA scale is ``--lora-scaled FILE:SCALE``, and the parser splits on
      ':' — so a drive letter breaks it. The adapter is passed by bare file
      name, with the process started in its directory.
    * On the GPU, Vulkan's cooperative-matrix shaders return empty or
      garbage answers for any prompt processed as a batch on Intel's
      driver; ``GGML_VK_DISABLE_COOPMAT=1`` makes the output match the CPU
      (64 of 65 answers identical) and is faster as well (prompt 1140 vs
      870 tok/s).
    * Qwen3.5 is a hybrid model, so the server reuses a cached prompt
      prefix through context checkpoints, and restoring one on Vulkan feeds
      the rest of the prompt a token at a time (~35 tok/s). Processing the
      whole prompt each time is faster there (p50 0.50 s vs 0.85 s). The
      CPU is the other way round (0.32 s with the cache, 0.75 s without), so
      it keeps them. Either way one request at a time (``--parallel 1``),
      as the dictation is sequential.
    """
    if os.path.basename(str(executable)).lower() != "llama-server.exe":
        # Our own host: the macOS flags, plus an explicit thread count (see
        # llm_thread_count) and, on the GPU, the same cooperative-matrix
        # workaround as llama-server. Prompt-prefix reuse is built in.
        argv = [str(executable),
                "--model", spec.model_path,
                "--host", "127.0.0.1",
                "--port", str(port),
                "--ctx-size", str(spec.context_size),
                "--gpu-layers", str(spec.gpu_layers),
                "--threads", str(llm_thread_count())]
        if spec.lora_path:
            argv += ["--lora", spec.lora_path, "--lora-scale", str(spec.lora_scale)]
        if spec.chat_template_path:
            argv += ["--chat-template-file", spec.chat_template_path]
        env = {"GGML_VK_DISABLE_COOPMAT": "1"} if spec.gpu_layers > 0 else {}
        return argv, None, env

    argv = [str(executable),
            "--model", spec.model_path,
            "--host", "127.0.0.1",
            "--port", str(port),
            "--ctx-size", str(spec.context_size),
            "--parallel", "1",
            "--no-webui"]
    env: dict[str, str] = {}
    if spec.gpu_layers > 0:
        argv += ["--gpu-layers", str(spec.gpu_layers), "--ctx-checkpoints", "0"]
        env["GGML_VK_DISABLE_COOPMAT"] = "1"
    else:
        argv += ["--device", "none", "--gpu-layers", "0"]
    cwd = None
    if spec.lora_path:
        cwd = os.path.dirname(spec.lora_path)
        argv += ["--lora-scaled", f"{os.path.basename(spec.lora_path)}:{spec.lora_scale:g}"]
    if spec.chat_template_path:
        argv += ["--chat-template-file", spec.chat_template_path]
    return argv, cwd, env


def _engine_environment() -> dict[str, str]:
    """The host's environment: where its Vulkan shaders are.

    The host is one static executable; Vulkan itself is the GPU driver's
    ``vulkan-1.dll``. The SPIR-V corpus is loaded from disk on first use,
    and without this variable the host would look for it beside the source
    tree it was compiled from. A value already set wins, for debugging a
    rebuilt corpus.
    """
    env = dict(os.environ)
    env.setdefault("SUPERDICTATE_VULKAN_SHADER_DIR",
                   str(paths.resource_path("engines", "vulkan-shaders")))
    return env


@dataclass(frozen=True)
class HostSpec:
    """Everything that identifies one host process.

    Two requests wanting the same spec share one process: the quality
    correction tier and the bundled rewrite both run YandexGPT, and loading
    it twice would cost a second 4.9 GB. The host serializes requests
    internally and the two stages are sequential anyway, so sharing is safe.
    """

    model_path: str
    lora_path: str = ""
    lora_scale: float = 1.0
    context_size: int = 4096
    gpu_layers: int = 99
    #: A chat-template override (LFM2.5), or "".
    chat_template_path: str = ""

    @property
    def identity(self) -> str:
        return f"{self.model_path}|{self.lora_path}|{'gpu' if self.gpu_layers else 'cpu'}"


class LLMHostProcess:
    """One running host process, owned by :class:`LLMHostPool`."""

    def __init__(self, spec: HostSpec) -> None:
        self.spec = spec
        self._process: Optional[subprocess.Popen] = None
        self._port = 0

    @property
    def is_running(self) -> bool:
        return self._process is not None and self._process.poll() is None

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self._port}"

    def start(self, *, timeout: float = HEALTH_TIMEOUT_SECONDS) -> None:
        """Spawn the host and block until ``/health`` answers.

        Raises :class:`LLMHostError` if the process dies first or never
        becomes ready — the caller decides whether that is fatal (it never
        is: the pipeline falls back to the uncorrected text).
        """
        executable = host_executable()
        if not os.path.exists(executable):
            raise LLMHostError(f"host binary not found: {executable}")

        self._port = _free_loopback_port()
        argv, cwd, extra_env = host_command(str(executable), self.spec, self._port)
        env = _engine_environment()
        for key, value in extra_env.items():
            env.setdefault(key, value)  # a value set by hand wins, for debugging

        started = time.monotonic()
        # The host's own stderr (model load, device, errors) goes to a log
        # file: the windowed app has no console to show it on.
        try:
            stderr = open(paths.LOG_DIR / "LLMHost.log", "ab")
        except OSError:
            stderr = subprocess.DEVNULL
        try:
            self._process = subprocess.Popen(
                argv,
                env=env,
                cwd=cwd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=stderr,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except OSError as exc:
            raise LLMHostError(f"could not launch host: {exc}") from exc
        finally:
            if stderr is not subprocess.DEVNULL:
                stderr.close()

        _kill_child_with_parent(self._process)

        deadline = started + timeout
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                raise LLMHostError(
                    f"host exited before becoming ready (code {self._process.returncode})")
            if self._health_ok():
                log.info("LLM host ready in %.1fs on port %d (%s)",
                         time.monotonic() - started, self._port,
                         os.path.basename(self.spec.model_path))
                return
            time.sleep(0.25)
        self.stop()
        raise LLMHostError(f"host did not answer /health within {timeout:.0f}s")

    def _health_ok(self) -> bool:
        try:
            with _OPENER.open(self.base_url + "/health", timeout=2) as response:
                return json.load(response).get("status") == "ok"
        except Exception:
            return False

    def stop(self) -> None:
        process, self._process = self._process, None
        if process is None or process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()

    def complete(self, messages: Sequence[Message], *,
                 max_tokens: int = 512,
                 temperature: Optional[float] = 0.0) -> str:
        """One chat completion. Returns the assistant's content.

        Greedy unless asked otherwise: the macOS host always is, and
        llama-server would otherwise sample at its default of 0.8, which
        makes the corrector answer differently to the same sentence.
        """
        return chat_completion(self.base_url, messages,
                               max_tokens=max_tokens, temperature=temperature)


def chat_completions_url(base_url: str) -> str:
    """The request URL for an endpoint address as people write it.

    Provider docs give the base with its version ("https://openrouter.ai/api/v1",
    OpenAI SDK style); local servers are usually given bare
    ("http://127.0.0.1:1234"). Both work, and so does the full URL.
    """
    url = base_url.strip().rstrip("/")
    if url.endswith("/chat/completions"):
        return url
    if url.endswith("/v1"):
        return url + "/chat/completions"
    return url + "/v1/chat/completions"


def chat_completion(base_url: str, messages: Sequence[Message], *,
                    max_tokens: int = 512,
                    temperature: Optional[float] = None,
                    api_key: str = "",
                    model: str = "superdictate-llm-host",
                    use_system_proxy: bool = True,
                    timeout: float = REQUEST_TIMEOUT_SECONDS) -> str:
    """POST ``/v1/chat/completions`` and return the assistant's content.

    Shared by the bundled host and a user-supplied OpenAI-compatible
    endpoint — the whole reason the host speaks this protocol at all.
    ``use_system_proxy`` only affects internet endpoints; LAN ones always
    go direct.
    """
    payload: dict[str, object] = {
        "model": model,
        "messages": [message.to_json() for message in messages],
        "max_tokens": max_tokens,
        # The host defaults thinking off; say so explicitly so a custom
        # endpoint running a reasoning model does not spend the budget on
        # a chain of thought the pipeline would only have to strip.
        "chat_template_kwargs": {"enable_thinking": False},
    }
    if temperature is not None:
        payload["temperature"] = temperature

    request = urllib.request.Request(
        chat_completions_url(base_url),
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    if api_key:
        request.add_header("Authorization", f"Bearer {api_key}")

    try:
        with _opener_for(request.full_url, use_system_proxy).open(
                request, timeout=timeout) as response:
            body = json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:400]
        raise LLMHostError(f"HTTP {exc.code}: {detail}") from exc
    except Exception as exc:
        raise LLMHostError(str(exc)) from exc

    choices = body.get("choices") or []
    if not choices:
        raise LLMHostError(f"no choices in response: {str(body)[:200]}")
    # A reasoning model that ran out of tokens answers "content": null;
    # str() of that would hand the pipeline the word "None" as the text.
    content = (choices[0].get("message") or {}).get("content")
    return content if isinstance(content, str) else ""


class LLMHostPool:
    """Keeps at most one host per :attr:`HostSpec.identity` alive.

    Hosts are started lazily on first use and kept for the process
    lifetime — a 4.9 GB model must not be reloaded per dictation — and are
    torn down together on shutdown or when the model settings change.
    """

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._hosts: dict[str, LLMHostProcess] = {}

    def get(self, spec: HostSpec) -> LLMHostProcess:
        """The running host for ``spec``, starting it if necessary."""
        with self._lock:
            existing = self._hosts.get(spec.identity)
            if existing is not None and existing.is_running:
                return existing
            if existing is not None:
                log.warning("LLM host for %s died; restarting", spec.identity)
                existing.stop()
            host = LLMHostProcess(spec)
            host.start()
            self._hosts[spec.identity] = host
            return host

    def discard(self, spec: HostSpec) -> None:
        """Stop the host for ``spec``, if there is one."""
        with self._lock:
            host = self._hosts.pop(spec.identity, None)
        if host is not None:
            host.stop()

    def shutdown(self) -> None:
        with self._lock:
            for host in self._hosts.values():
                host.stop()
            self._hosts.clear()


# -- orphan prevention -----------------------------------------------

_JOB_HANDLE = None
_JOB_LOCK = threading.Lock()


def _kill_child_with_parent(process: subprocess.Popen) -> None:
    """Assign ``process`` to a job that dies with this one.

    The host runs its own parent-death watchdog, but that is a
    poll-and-hope arrangement that a hard kill can outrun. A job object
    with ``JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`` is the OS doing the same
    job properly: when this process exits, for any reason, the handle
    closes and every process in the job goes with it.

    Best-effort by design — a failure here costs a possible orphan, never
    a working dictation, so it is logged and swallowed.
    """
    global _JOB_HANDLE
    try:
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

        with _JOB_LOCK:
            if _JOB_HANDLE is None:
                job = kernel32.CreateJobObjectW(None, None)
                if not job:
                    raise ctypes.WinError(ctypes.get_last_error())

                # JOBOBJECT_EXTENDED_LIMIT_INFORMATION, laid out by hand so
                # this needs no external dependency.
                class IO_COUNTERS(ctypes.Structure):
                    _fields_ = [(name, ctypes.c_ulonglong) for name in (
                        "ReadOperationCount", "WriteOperationCount",
                        "OtherOperationCount", "ReadTransferCount",
                        "WriteTransferCount", "OtherTransferCount")]

                class BASIC_LIMIT(ctypes.Structure):
                    _fields_ = [
                        ("PerProcessUserTimeLimit", ctypes.c_int64),
                        ("PerJobUserTimeLimit", ctypes.c_int64),
                        ("LimitFlags", wintypes.DWORD),
                        ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t),
                        ("ActiveProcessLimit", wintypes.DWORD),
                        ("Affinity", ctypes.POINTER(ctypes.c_ulong)),
                        ("PriorityClass", wintypes.DWORD),
                        ("SchedulingClass", wintypes.DWORD),
                    ]

                class EXTENDED_LIMIT(ctypes.Structure):
                    _fields_ = [
                        ("BasicLimitInformation", BASIC_LIMIT),
                        ("IoInfo", IO_COUNTERS),
                        ("ProcessMemoryLimit", ctypes.c_size_t),
                        ("JobMemoryLimit", ctypes.c_size_t),
                        ("PeakProcessMemoryUsed", ctypes.c_size_t),
                        ("PeakJobMemoryUsed", ctypes.c_size_t),
                    ]

                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION = 9

                limits = EXTENDED_LIMIT()
                limits.BasicLimitInformation.LimitFlags = \
                    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                if not kernel32.SetInformationJobObject(
                        job, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
                        ctypes.byref(limits), ctypes.sizeof(limits)):
                    raise ctypes.WinError(ctypes.get_last_error())
                _JOB_HANDLE = job

        handle = int(process._handle)  # type: ignore[attr-defined]
        if not kernel32.AssignProcessToJobObject(_JOB_HANDLE,
                                                 wintypes.HANDLE(handle)):
            raise ctypes.WinError(ctypes.get_last_error())
    except Exception as exc:  # pragma: no cover - platform detail
        log.debug("Could not assign LLM host to a job object: %s", exc)
