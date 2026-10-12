# ComfyUI-SwarmUI-Install-Helper

**Initial author: Sean Tu — [@sajtu on GitHub](https://github.com/sajtu)**

[Project repository](https://github.com/sajtu/ComfyUI-SwarmUI-Install-Helper.git or git@github.com:/sajtu/ComfyUI-SwarmUI-Install-Helper.git)

## Read before running — disclaimer and responsibility

**Provided “as is” and “as available,” without warranty of any kind. Review the
code before executing it. Do not rely on this README, a successful test, or any
project description as proof that the scripts are safe or suitable for your
system.**

Sean Tu has successfully tested and used the helper in their own environment,
but makes no guarantee of compatibility, safety, reliability, or results in
other environments or with future upstream changes. This project is shared for
education and community benefit.

Perform your own due diligence: inspect the scripts and the software they
download, consult official documentation and licenses, and decide whether the
setup is appropriate for your environment. Maintain recoverable backups and
consider testing in an isolated lab or disposable environment before using a
machine with important data or services. You are responsible for your decision
to execute the code, the privileges you grant, and your system’s configuration,
credentials, access controls, and recovery arrangements.

To the maximum extent permitted by applicable law, the author and contributors
disclaim all express and implied warranties, including merchantability, fitness
for a particular purpose, and non-infringement, and shall not be liable for
claims, losses, or damages arising from use of, inability to use, or reliance on
this project. This includes data loss, system damage, downtime, lost profits,
and direct, indirect, incidental, special, or consequential damages, even if
advised of their possibility. This notice does not exclude rights or obligations
that cannot legally be excluded.

**This README is an overview of this helper, not a replacement for official
ComfyUI, SwarmUI, and model documentation or third-party guides. Follow the original projects’
documentation as the source of truth for their software and models.**

## Purpose and scope

An interactive installation and launch helper for **ComfyUI and SwarmUI on compatible Ubuntu systems with an NVIDIA GPU**.

The purpose is straightforward: check prerequisites, download the applications and an illustration model, configure their environments, and get a local image generator running with fewer manual steps and less command memorization. It was created to simplify the author's own setup and is shared for experimentation, education, and community benefit.

This is an independent helper. It is not affiliated with, sponsored by, endorsed by, or an official product of ComfyUI, SwarmUI, Cagliostro Labs, Microsoft, NVIDIA, Ubuntu, or other third parties. It automates setup; it does not claim ownership of their applications, libraries, or models.

Feedback and bug reports can be submitted through [GitHub Issues](https://github.com/sajtu/ComfyUI-SwarmUI-Install-Helper/issues). Remove passwords, tokens, private images, prompts, and other sensitive information before sharing logs.

## What this installs

- **[ComfyUI](https://github.com/Comfy-Org/ComfyUI):** the image-generation engine and its node/workflow browser interface. This helper uses it as SwarmUI's local backend. See the [official documentation](https://docs.comfy.org/) for upstream capabilities and setup details.
- **[SwarmUI](https://github.com/mcmonkeyprojects/SwarmUI):** a browser frontend with prompt entry, generation controls, image history, and additional workflows. Its [original documentation](https://github.com/mcmonkeyprojects/SwarmUI/tree/master/docs) is the source of truth for using it.
- **[Animagine XL 4.0 Opt](https://huggingface.co/cagliostrolab/animagine-xl-4.0):** the included anime/illustration checkpoint from Cagliostro Labs. Review its model card, usage guidance, and license before use or redistribution.

These descriptions identify the intended projects; they do not replace official documentation. Available features depend on versions, installed models, extensions, and hardware. The helper does not install every model or dependency needed for every feature shown in the interface. Image-to-image may be available through Init Image; advanced pose, identity, video, or other controls can require additional setup. Prompts do not guarantee exact poses, anatomy, colors, or character consistency.

## What the helper does

- Checks Ubuntu, architecture, NVIDIA driver availability, GPU memory, and storage.
- Detects managed services and GPU compute workloads before installation.
- Collects setup choices before stopping services or installing dependencies.
- Installs an isolated Python environment and a private .NET SDK/runtime.
- Downloads the included checkpoint and checks that it can be read.
- Configures SwarmUI to use the local ComfyUI backend and shared checkpoint.
- Creates **one public launcher, `start-comfyswarm.sh`**, inside the installation.
- Offers in-place repair or a fresh installation with a renamed backup.
- Optionally adds the installation to PATH and creates a Bash/Zsh alias.
- Starts applications in the background without installing a systemd service.
- Optionally generates and checks a 1024 × 1024 test image after startup.
- Prints a quick guide and reminders about retained backup directories and their disk usage.

Terminal output uses leading spaces and paragraph spacing for readability. Third-party progress output may still use its own formatting.

## Requirements and dependencies

The installer targets **Ubuntu x86-64 with an NVIDIA GPU**, using Bash. It has been tested by the author on Ubuntu 24.04 with a Quadro RTX 6000. Other combinations and future upstream versions are not guaranteed.

| Requirement | Current helper policy |
|---|---|
| Operating system | Ubuntu, x86-64 |
| NVIDIA driver | Working `nvidia-smi`; version at least `570.26` |
| GPU | Runtime check requires Turing / compute capability 7.5 or newer |
| GPU memory | At least 8 GiB total and free after approved shutdown |
| Storage | At least 30 GiB free; retained backups and additional models occupy extra space |
| Python | Isolated, `uv`-managed Python 3.12 |
| PyTorch | Helper pins PyTorch 2.10.0 and TorchVision 0.25.0 with CUDA 12.8 wheels |
| .NET | Private .NET 8 SDK and ASP.NET Core runtime for the current SwarmUI build |
| Network | Access to GitHub, Hugging Face, Python/package hosts, NuGet, and Microsoft download hosts |
| Permissions | Normal user recommended; administrator authorization for missing Ubuntu packages |

System packages checked:

```text
git curl ca-certificates build-essential libgl1 libglib2.0-0t64 util-linux libicu-dev
```

Older Ubuntu versions use `libglib2.0-0` instead of the `t64` package name. `util-linux` supplies process-locking and detached-process tools. Additional Python dependencies follow ComfyUI's requirements and any included SwarmUI node requirements.

**This helper does not install or upgrade NVIDIA drivers.** Install a suitable driver and reboot first if the driver check fails. No manual activation of an Ollama, vLLM, or Python environment is required.

Resource checks are preliminary thresholds, not a guarantee that every resolution, batch size, or model will fit.

### Current upstream dependency notices

The tested SwarmUI build uses **ImageSharp 3.1.12**, which produces known-vulnerability warnings during its .NET build. The helper retains the upstream dependency configuration; those warnings are **not resolved or suppressed**. Review the advisories linked in your build output and the [upstream dependency file](https://github.com/mcmonkeyprojects/SwarmUI/blob/master/src/SwarmUI.deps.props).

An attempted newer-library upgrade required a Six Labors build license and was removed from this helper. Consult [Six Labors licensing](https://sixlabors.com/pricing/) before independently changing those dependencies.

The current helper installs .NET 8. A notice in SwarmUI about a future .NET 10 requirement does not mean .NET 8 failed to install. Future upstream releases may require an updated installer; this helper does not currently install .NET 10.

## Download

Using HTTPS:

```bash
git clone https://github.com/sajtu/ComfyUI-SwarmUI-Install-Helper.git
```

Or SSH, with GitHub SSH access already configured:

```bash
git clone git@github.com:sajtu/ComfyUI-SwarmUI-Install-Helper.git
```

## Install

Review the script before executing it. Run as the user who should own the installation:

```bash
cd ComfyUI-SwarmUI-Install-Helper
chmod +x install-ComfySwarmUI.sh
./install-ComfySwarmUI.sh
```

Alternatively:

```bash
bash install-ComfySwarmUI.sh
```

The default destination is:

```text
$HOME/apps/ComfySwarmUI
```

Running as root uses root's home and authority. A normal user installation requests administrator authorization only when missing system packages require it.

### Questions first, installation afterward

The installer collects the relevant choices before beginning changes:

1. If managed services or GPU workloads are detected, ask for permission to stop the listed blockers **if installation proceeds**. Consent is collected; processes are not stopped yet.
2. Detect an existing installation. Offer reinstall/repair; if declined, skip installation and offer startup of the existing servers.
3. When reinstalling, offer a fresh installation instead of repair in place. Only a new installation receives the installation-destination confirmation.
4. Collect PATH/alias, post-install startup, and LAN-access choices.
5. Check prerequisites and ask about installing missing system packages, `uv`, Python, and .NET.
6. Execute approved shutdown and installation without further setup questions.

If startup was requested and succeeds, the installer offers the optional test image. Its default is **No**. If startup was declined, there is no test-image question.

Setup can still fail because of downloads, package repositories, permissions, hardware, or upstream changes. Do not interpret collecting the answers as a guarantee that installation will finish successfully.

### Stopping blocking workloads

After consent, managed SwarmUI is stopped before ComfyUI. Remaining identified GPU workloads owned by the current user receive graceful termination, followed by force termination if they do not exit after waiting. This can discard unsaved work, interrupt jobs, or stop another local AI application. Read the displayed process list before approving.

Workloads owned by another user must be handled by that user or the appropriate administrator. If a supervisor restarts a workload, the installer stops with an explanation rather than repeatedly killing new processes. Declining reinstall means the earlier conditional shutdown consent is not acted on.

### Repair, fresh install, and backups

**In-place repair** reuses the directory and existing checkpoint, refreshes dependencies, rebuilds SwarmUI, and replaces helper-generated files. Existing SwarmUI settings/backend files are retained when present. This is not a rollback transaction or a guarantee that every local customization is preserved.

The current repair flow does not automatically advance the ComfyUI checkout. A clean SwarmUI checkout is offered a fast-forward Git update; a checkout with tracked local changes is built at its current state. Upstream dependency changes may affect future repairs.

**Fresh install** renames the entire old directory, for example:

```text
$HOME/apps/ComfySwarmUI.old-2026-10-11_21-30-00
```

It then creates a new installation without copying settings, outputs, models, or other files from that backup. Shared download caches outside the installation may still be reused. The timestamp follows the server's clock and timezone.

The helper also detects the legacy `$HOME/apps/ComfyUI` directory. An in-place repair keeps that path; a fresh installation backs it up and uses the new default `$HOME/apps/ComfySwarmUI` path. `IMAGE_INSTALL_DIR` overrides the default lookup behavior.

Backups remain until you delete them manually. Exit reminders list matching `.old*` directories and their measured disk usage. Inspect them, recover needed files, and confirm the new installation before deleting anything. Renamed Python environments and stored absolute paths may need restoration to their original location or repair before they can run; a renamed backup is not automatically a runnable alternate installation.

### Installer options

**The installer accepts no CLI switches, including no `--help` switch.** It is interactive. Use these environment variables to customize installation:

| Variable | Default | Purpose |
|---|---|---|
| `IMAGE_INSTALL_DIR` | `$HOME/apps/ComfySwarmUI` | Absolute installation path |
| `IMAGE_GPU_INDEX` | `0` | Physical GPU index reported by `nvidia-smi` |

```bash
IMAGE_INSTALL_DIR="$HOME/apps/ComfySwarmUI" IMAGE_GPU_INDEX=0 bash install-ComfySwarmUI.sh
```

## Start and stop

If you accepted shell setup, open a new shell or source the updated Bash profile:

```bash
source ~/.bashrc
start-comfyswarm
```

For Zsh, source the configured `.zshrc` instead. Without an alias:

```bash
"$HOME/apps/ComfySwarmUI/start-comfyswarm.sh"
```

The launcher sets up the application environments itself. Default startup asks whether to allow LAN access; **No** is the default. It starts ComfyUI first, waits for its HTTP service, then starts SwarmUI. Already-running managed services are reused where applicable. Both run in the background and may survive SSH disconnection.

| Interface | Default address | Role |
|---|---|---|
| SwarmUI | `http://127.0.0.1:7801` | Main prompt-and-generate frontend |
| ComfyUI | `http://127.0.0.1:8188` | Backend and node/workflow interface |

The frontend connects to ComfyUI locally. Normal stack LAN mode exposes SwarmUI while keeping its automatically launched backend local.

```bash
start-comfyswarm --status
start-comfyswarm --stop
start-comfyswarm --restart
start-comfyswarm --kill
```

Stop and kill operate on SwarmUI first, then ComfyUI. Restart stops the stack before starting it again; specify startup choices if you do not want an interactive LAN question. `--kill` is abrupt and can interrupt generation.

The helper does not configure browser login, HTTPS, firewall rules, public sharing, or systemd. LAN access is unprotected in this setup. Use localhost and SSH forwarding for private remote access, or configure access controls separately using official guidance.

### Launcher switches

| Switch | Purpose |
|---|---|
| `--help`, `-h` | Display public launcher usage |
| `--local` | Localhost access; skip LAN question |
| `--lan` | LAN access; skip LAN question |
| `--non-interactive` | Require explicit `--local` or `--lan` for startup |
| `--auto` | Automatic model precision; FP16 on supported GPUs, FP32 VAE |
| `--fp16` | Request FP16 image model/text encoder; VAE remains FP32 |
| `--fp32` | Force FP32 for the image backend; may require more memory |
| `--gpu INDEX` | Select GPU when starting the backend |
| `--port NUMBER` | Set SwarmUI port in normal stack mode; default `7801` |
| `--background` | Background operation; default |
| `--status` | Report managed process status for both services |
| `--stop` | Gracefully stop both services |
| `--kill` | Force-stop both services |
| `--restart` | Restart both services |
| `--service comfyui` | Target ComfyUI for individual debugging/control |
| `--service swarmui` | Target SwarmUI for individual debugging/control |
| `--logs --service NAME` | Print the selected service's last 80 log lines |

The public launcher does **not** support `--foreground`. There is no helper model-selection switch; choose an installed compatible model in the browser.

Fully non-interactive startup/restart:

```bash
start-comfyswarm --local --non-interactive
start-comfyswarm --restart --local --non-interactive
```

Debugging one service:

```bash
start-comfyswarm --restart --service comfyui --local --non-interactive
start-comfyswarm --restart --service swarmui --local --non-interactive
start-comfyswarm --logs --service comfyui
start-comfyswarm --logs --service swarmui
```

Restarting/stopping only ComfyUI can temporarily leave SwarmUI without its backend. Starting only SwarmUI may start ComfyUI when its dependency is unavailable. Keep the backend on port `8188` unless you also update the SwarmUI backend configuration. Startup switches do not reconfigure an already-running service; restart to apply changes.

### Process locks and logs

Kernel-backed locks prevent duplicate managed sessions per installation. Process metadata and Linux start-time checks help avoid signalling a recycled PID. A crash releases the kernel lock; the lock file may remain and should not be deleted while a service is running.

`--status` checks recorded processes, not a complete generation test. Normal stack startup additionally checks HTTP readiness. Logs are stored in the installation:

```text
image-server.log
swarm-server.log
```

The launcher reports sibling installation backups at the end of standalone runs. Installer-triggered startup leaves that reminder to the installer to avoid printing it twice.

## Private remote browser access with SSH

These instructions work from **Linux, macOS, or Windows with an SSH client**. Run the tunnel command on the computer where you will use the browser, not on the AI server:

```bash
ssh -N -o ExitOnForwardFailure=yes   -L 127.0.0.1:7801:127.0.0.1:7801   your-user@your-ubuntu-host
```

Then open **http://localhost:7801** in that computer's browser. Keep the tunnel terminal open. Ctrl+C closes the tunnel but does not stop background services. The AI server must have SSH installed, running, and reachable.

If the client port is occupied:

```bash
ssh -N -o ExitOnForwardFailure=yes   -L 127.0.0.1:7802:127.0.0.1:7801   your-user@your-ubuntu-host
```

Open `http://localhost:7802`. If SwarmUI uses a different server port, change the last port in the forwarding rule.

For direct ComfyUI access, add a second forwarding rule:

```bash
ssh -N -o ExitOnForwardFailure=yes   -L 127.0.0.1:7801:127.0.0.1:7801   -L 127.0.0.1:8188:127.0.0.1:8188   your-user@your-ubuntu-host
```

Then open `http://localhost:8188` for ComfyUI. SSH forwarding does not require enabling LAN access or opening these application ports on the server firewall.

## First image

Open SwarmUI, select the included Animagine model, enter a positive prompt and optional negative prompt, choose settings, and click **Generate**. Check [SwarmUI usage documentation](https://github.com/mcmonkeyprojects/SwarmUI/blob/master/docs/Basic%20Usage.md) and the [Animagine model card](https://huggingface.co/cagliostrolab/animagine-xl-4.0) for guidance.

If you request the installer's test after startup, it submits a generic illustration prompt, checks the returned image is 1024 × 1024 and nonblank, and reports success. This verifies a basic generation path; it does not certify image quality, anatomy, security, or every UI feature.

For users who prefer ComfyUI's graph interface, the helper also creates `workflows/comfyui-starter.json`. SwarmUI prompt entry does not require editing that JSON.

## Troubleshooting

- **`start-comfyswarm` not found:** open a new shell, source the profile, or run the full launcher path.
- **Browser unavailable:** check both services' status and logs, then verify the SSH tunnel or LAN route and ports.
- **Port occupied:** inspect the owner. The helper does not kill an arbitrary process merely because it owns a port.
- **GPU workload restarts after shutdown:** stop its supervising service separately before retrying.
- **Missing prerequisites declined:** installation stops; complete the prerequisites or rerun and approve them.
- **APT repository error:** fix the affected repository rather than disabling security checks.
- **GPU memory exhausted:** reduce resolution/batch size, unload other models, or use a suitable smaller model. FP32 increases memory use.
- **ImageSharp warnings:** these are retained upstream dependency warnings, not proof of a failed build or resolved security issues.
- **Future .NET requirement:** consult upstream and update the helper as needed; the current private runtime is .NET 8.
- **Unexpected image content:** check the selected model, prompts, seed, and Init Image settings. Pose/identity control may require appropriate additional models; a longer prompt is not a guarantee of compliance.

## Third-party acknowledgments and original sources

These brief descriptions identify major components. **Consult the original projects for authoritative documentation, licenses, security notices, and current requirements.**

| Project | Brief role | Original source |
|---|---|---|
| ComfyUI / Comfy Org and contributors | Generation backend and workflow interface | [GitHub](https://github.com/Comfy-Org/ComfyUI), [docs](https://docs.comfy.org/) |
| SwarmUI / mcmonkey and contributors | Browser frontend; formerly StableSwarmUI | [GitHub](https://github.com/mcmonkeyprojects/SwarmUI) |
| Cagliostro Labs / Animagine | Included illustration checkpoint | [Model card](https://huggingface.co/cagliostrolab/animagine-xl-4.0), [GitHub organization](https://github.com/cagliostrolab) |
| Astral uv | Python/runtime and environment management | [GitHub](https://github.com/astral-sh/uv) |
| Python | Interpreter and helper checks | [CPython](https://github.com/python/cpython) |
| PyTorch / TorchVision | Tensor computation and image-model dependencies | [PyTorch](https://github.com/pytorch/pytorch), [TorchVision](https://github.com/pytorch/vision) |
| Hugging Face ecosystem | Checkpoint hosting, downloads, model tooling | [Hub client](https://github.com/huggingface/huggingface_hub), [Transformers](https://github.com/huggingface/transformers), [Safetensors](https://github.com/huggingface/safetensors) |
| Microsoft / .NET and ASP.NET Core | SwarmUI build/runtime | [.NET SDK](https://github.com/dotnet/sdk), [ASP.NET Core](https://github.com/dotnet/aspnetcore) |
| Six Labors | SwarmUI image-processing dependencies | [ImageSharp](https://github.com/SixLabors/ImageSharp), [Drawing](https://github.com/SixLabors/ImageSharp.Drawing) |
| Pillow | Test-image inspection | [GitHub](https://github.com/python-pillow/Pillow) |
| Ubuntu / Canonical and contributors | Operating system and system packages | [Ubuntu](https://ubuntu.com/), [Canonical GitHub](https://github.com/canonical) |
| NVIDIA | GPU drivers and CUDA ecosystem | [CUDA documentation](https://docs.nvidia.com/cuda/), [GitHub](https://github.com/NVIDIA) |
| Git / curl | Repository retrieval and downloads | [Git](https://github.com/git/git), [curl](https://github.com/curl/curl) |
| util-linux | Locks and detached process sessions | [GitHub](https://github.com/util-linux/util-linux) |
| GNU and shell-tool contributors | Bash and command-line utilities | [Bash](https://www.gnu.org/software/bash/), [Coreutils](https://www.gnu.org/software/coreutils/), [GNU awk](https://www.gnu.org/software/gawk/), [mawk](https://invisible-island.net/mawk/) |
| OpenSSH | Optional private remote access | [Official project](https://www.openssh.com/), [GitHub](https://github.com/openssh/openssh-portable) |

Copyrights and credit belong to the respective authors, contributors, and rights holders. Names and trademarks identify components and do not imply affiliation or endorsement. This list is not an exhaustive inventory; actual packages may change with upstream releases.

A license supplied for this helper covers only material its author has the right to license. It does not relicense third-party code, model weights, or generated/reference content. Review the original terms before use or redistribution and preserve applicable copyright and license notices. The disclaimer near the top also applies to this overview.
