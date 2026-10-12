#!/usr/bin/env bash
# Ubuntu x86-64 / NVIDIA ComfyUI installer. Review before execution.
set -Eeuo pipefail
output_sync_dir=$(mktemp -d)
format_output() {
    awk -v ack="$1" '
        $0 == "__HELPER_OUTPUT_BARRIER__" { print "ready" > ack; close(ack); next }
        { print " " $0; fflush() }
    '
}
exec > >(format_output "$output_sync_dir/stdout") 2> >(format_output "$output_sync_dir/stderr" >&2)
sync_output() {
    rm -f "$output_sync_dir/stdout" "$output_sync_dir/stderr"
    printf '__HELPER_OUTPUT_BARRIER__\n'
    printf '__HELPER_OUTPUT_BARRIER__\n' >&2
    local attempt
    for ((attempt=0; attempt<500; attempt++)); do
        if [[ -f "$output_sync_dir/stdout" && -f "$output_sync_dir/stderr" ]]; then return 0; fi
        sleep 0.01
    done
    printf 'Output flush timed out; prompt cancelled.\n' >&2
    return 1
}
print_quick_guide(){
 printf '\nQuick guide (open a new shell after adding the alias):\n'
 printf '  start-comfyswarm             Start both services\n'
 printf '  start-comfyswarm --stop      Stop both services\n'
 printf '  start-comfyswarm --restart   Restart both services\n'
 printf '  start-comfyswarm --kill      Force-stop both services\n'
 printf '  start-comfyswarm --status    Check both services\n'
 printf '  start-comfyswarm --logs --service comfyui\n'
 printf '  start-comfyswarm --logs --service swarmui\n'
 printf 'Without an alias, run: %s/start-comfyswarm.sh [options]\n' "$dest"
}
backup_paths=(); backup_sizes=()
collect_install_backups(){
 local install_dir=${1%/} candidate size
 local parent=${install_dir%/*} base=${install_dir##*/}
 for candidate in "$parent/$base.old"*; do
  [[ -d "$candidate" && ! -L "$candidate" ]] || continue
  size=$(du -sh -- "$candidate" 2>/dev/null | cut -f1) || size='unknown'
  backup_paths+=("$candidate"); backup_sizes+=("${size:-unknown}")
 done
}
print_backup_reminder(){
 ((${#backup_paths[@]})) || return 0
 printf '\nPrevious installation backups (disk usage measured when this command began):\n'
 local index
 for index in "${!backup_paths[@]}"; do
  printf '  %s  %s\n' "${backup_sizes[index]}" "${backup_paths[index]}"
 done
 printf '\nInspect these directories and keep any files you need.\n'
 printf 'When you are sure they are no longer needed, delete them manually to recover disk space.\n'
 printf 'This script does not delete backups.\n\n'
}
printf '\n\n'
trap 'if [[ -n ${backup_dest:-} ]]; then printf "\nFresh-install backup retained at: %s\n" "$backup_dest"; fi; if [[ -x ${dest:-}/start-comfyswarm.sh ]]; then print_quick_guide; fi; print_backup_reminder; printf "\n\n"; sync_output || true; rm -rf -- "$output_sync_dir"' EXIT
trap 'printf "\nSetup stopped at line %s. Fix the reported error before retrying.\n" "$LINENO" >&2' ERR
fail(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
ask(){
 local answer default=${2:-no} label='[y/N]'
 [[ "$default" != yes ]] || label='[Y/n]'
 [[ -r /dev/tty ]] || fail 'Interactive terminal required.'
 while true; do
  sync_output
  printf '\n %s %s: ' "$1" "$label" >/dev/tty
  read -r answer </dev/tty || return 1
  case "$answer" in
   '') [[ "$default" == yes ]]; return ;;
   y|Y|yes|YES) return 0 ;;
   n|N|no|NO) return 1 ;;
   *) printf ' Please answer yes or no.\n' >/dev/tty ;;
  esac
 done
}
[[ $# == 0 ]] || fail 'Set IMAGE_INSTALL_DIR / IMAGE_GPU_INDEX to customize; no installer arguments.'
[[ -f /etc/os-release ]] || fail 'Ubuntu required.'
source /etc/os-release
[[ "$ID" == ubuntu && "$(uname -m)" == x86_64 ]] || fail 'This helper supports Ubuntu x86-64.'
dest=${IMAGE_INSTALL_DIR:-"$HOME/apps/ComfySwarmUI"}
dest=${dest%/}
gpu=${IMAGE_GPU_INDEX:-0}
[[ "$dest" == /* && -n "$dest" && "$gpu" =~ ^[0-9]+$ ]] || fail 'Absolute install path and numeric GPU index required.'
printf 'Image generator: SwarmUI + ComfyUI + Animagine XL 4.0 Opt\nDefault install directory: %s\n' "$dest"
printf '\nModel terms: https://huggingface.co/cagliostrolab/animagine-xl-4.0\n'
export PATH="$HOME/.local/bin:$PATH"
resume=false; fresh_install=false; stop_approved=false
add_profile=false; start_after=false; access_flag=--local
# Discover services/workloads first; only collect consent here.
command -v nvidia-smi >/dev/null || fail 'Install a compatible NVIDIA driver and reboot first.'
workload_pids=(); workload_tokens=(); blocked=false
service_roots=(); scan_roots=("$dest")
if [[ -z ${IMAGE_INSTALL_DIR:-} && -d "$HOME/apps/ComfyUI" ]]; then scan_roots+=("$HOME/apps/ComfyUI"); fi
process_token(){
 local data
 [[ -r "/proc/$1/stat" ]] || return 1
 data=$(cat "/proc/$1/stat") || return 1
 data=${data##*) }
 local fields; read -ra fields <<<"$data"
 [[ ${fields[0]:-Z} != Z ]] || return 1
 printf '%s' "${fields[19]}"
}
gpu_workloads=$(nvidia-smi -i "$gpu" --query-compute-apps=pid,process_name,used_gpu_memory --format=csv,noheader,nounits) || fail 'Cannot inspect GPU workloads.'
while IFS=, read -r pid process memory; do
 pid=${pid//[[:space:]]/}; [[ "$pid" =~ ^[0-9]+$ ]] || continue
 token=$(process_token "$pid") || continue
 owner=$(stat -c %u "/proc/$pid") || continue
 printf '\nGPU workload: PID %s; %s; %s MiB; UID %s\n' "$pid" "$process" "$memory" "$owner"
 [[ "$owner" == "$EUID" ]] || fail 'A workload belongs to another user; ask its owner to stop it before installation.'
 workload_pids+=("$pid"); workload_tokens+=("$token"); blocked=true
done <<<"$gpu_workloads"
for root in "${scan_roots[@]}"; do
 [[ -d "$root" ]] || continue
 collect_install_backups "$root"
 root_active=false
 for service in swarm image; do
  metadata="$root/.$service-server.json"
  if [[ -r "$metadata" ]]; then
   pid=$(sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p' "$metadata")
   token=$(sed -n 's/.*"start_token": *"\([0-9][0-9]*\)".*/\1/p' "$metadata")
   if [[ "$pid" =~ ^[0-9]+$ && -n "$token" && $(process_token "$pid" || true) == "$token" ]]; then
    printf '\nManaged %s service is running at %s (PID %s).\n' "$service" "$root" "$pid"
    root_active=true; blocked=true
   fi
  fi
  if command -v flock >/dev/null && [[ -f "$root/.$service-session.lock" ]] && ! flock -n "$root/.$service-session.lock" true; then
   root_active=true; blocked=true
  fi
 done
 [[ "$root_active" == false ]] || service_roots+=("$root")
done
if [[ "$blocked" == true ]]; then
 printf '\nThe listed workloads may have unsaved work. Nothing will stop until all setup choices are collected.\n'
 if ask 'Allow stopping ALL listed blocking services/workloads, including force-stop after waiting, if installation proceeds?'; then stop_approved=true; fi
fi
# Prefer the combined directory; preserve a legacy installation in place unless fresh is chosen.
existing=''
if [[ -e "$dest" ]]; then existing="$dest"
elif [[ -z ${IMAGE_INSTALL_DIR:-} && -e "$HOME/apps/ComfyUI" ]]; then existing="$HOME/apps/ComfyUI"
fi
if [[ -n "$existing" ]]; then
 printf '\nExisting installation found at: %s\n' "$existing"
 if ! ask 'Reinstall/repair this installation?'; then
  if ask 'Start the existing servers?'; then
   if ask 'Allow LAN browser access?'; then access_flag=--lan; fi
   launcher="$existing/start-comfyswarm.sh"
   [[ -x "$launcher" ]] || launcher="$existing/start-swarm.sh"
   [[ -x "$launcher" ]] || fail 'Launcher missing; repair is needed before starting.'
   bash "$launcher" "$access_flag" --non-interactive
  fi
  dest="$existing"
  exit 0
 fi
 command -v git >/dev/null || fail 'git is required to verify an existing checkout.'
 origin=$(git -C "$existing" remote get-url origin) || fail 'Existing path is not a Git checkout.'
 case "$(printf '%s' "$origin" | tr '[:upper:]' '[:lower:]')" in https://github.com/comfy-org/comfyui.git|https://github.com/comfyanonymous/comfyui.git) ;; *) fail 'Unexpected repository; no files changed.';; esac
 printf '\nFresh install renames %s to %s.old-YYYY-MM-DD_HH-MM-SS.\n' "$existing" "$existing"
 printf 'Nothing is copied back. Keep the backup until you are ready to delete it to recover disk space.\n'
 if ask 'Perform a fresh install instead of repairing in place?'; then
  [[ ! -L "$existing" ]] || fail 'Fresh install does not support a symlink installation.'
  fresh_install=true
 else
  dest="$existing"; resume=true
  printf '\nRepairing in place at %s.\n' "$dest"
 fi
else
 ask "Install ComfyUI and SwarmUI into $dest?" yes || fail 'Installation declined.'
 collect_install_backups "$dest"
fi
[[ "$blocked" == false || "$stop_approved" == true ]] || fail 'Installation requires permission to stop the listed blockers; no services were stopped.'
if ask 'Add start-comfyswarm alias and installation directory to your shell profile?'; then add_profile=true; fi
if ask 'Start both servers after successful installation?' yes; then
 start_after=true
 if ask 'Allow LAN browser access?'; then access_flag=--lan; fi
fi
# Validate capacity and collect every prerequisite choice before making changes.
probe=$(dirname "$dest"); while [[ ! -d "$probe" ]]; do probe=$(dirname "$probe"); done
free=$(df -Pk "$probe" | awk 'END {print $4}')
((free>=30*1024*1024)) || fail 'At least 30 GiB free storage required; fresh installs keep the old files too.'
info=$(nvidia-smi -i "$gpu" --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits)
printf '\nGPU: %s\n' "$info"
IFS=, read -r name driver total <<<"$info"
driver=${driver//[[:space:]]/}; total=${total//[[:space:]]/}
[[ "$total" =~ ^[0-9]+$ ]] && ((total>=8192)) || fail 'At least 8 GiB GPU memory required.'
dpkg --compare-versions "$driver" ge 570.26 || fail 'Driver 570.26 or newer is required.'
admin=(); ((EUID==0)) || admin=(sudo)
missing=()
for package in git curl ca-certificates build-essential libgl1 libglib2.0-0t64 util-linux libicu-dev; do
 [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" == 'install ok installed' ]] || missing+=("$package")
done
if dpkg --compare-versions "$VERSION_ID" lt 24.04; then
 for i in "${!missing[@]}"; do [[ "${missing[i]}" != libglib2.0-0t64 ]] || missing[i]=libglib2.0-0; done
fi
if ((${#missing[@]})); then
 printf '\nMissing system prerequisites: %s\n' "${missing[*]}"
 ask 'Install all listed system prerequisites?' yes || fail 'Prerequisites declined; no services were stopped.'
 if ((EUID!=0)); then
  command -v sudo >/dev/null || fail 'sudo required for system prerequisites.'
  sudo -v || fail 'Administrator authorization failed.'
 fi
fi
need_uv=false; need_python=false; need_dotnet=false
if ! command -v uv >/dev/null; then
 need_uv=true; need_python=true
 ask 'Install uv and its isolated Python 3.12 runtime?' yes || fail 'Python prerequisites declined.'
elif ! uv python find --managed-python 3.12 >/dev/null 2>&1; then
 need_python=true
 ask 'Install an isolated Python 3.12 runtime?' yes || fail 'Python prerequisite declined.'
fi
if [[ "$fresh_install" == true || ! -x "$dest/SwarmUI/.dotnet/dotnet" ]]; then
 need_dotnet=true
 ask 'Install the private .NET SDK/runtime required by SwarmUI?' yes || fail '.NET prerequisite declined.'
fi
printf '\nSetup choices collected. Installation will now proceed without further setup questions.\n'
# Execute approved shutdown in dependency order, then install prerequisites.
if ((${#missing[@]})) && ((EUID!=0)); then
 sudo -n true || fail 'Administrator authorization expired; no services were stopped. Retry setup.'
 admin=(sudo -n)
fi
if [[ "$stop_approved" == true ]]; then
 for root in "${service_roots[@]}"; do
  frontend_launcher="$root/start-comfyswarm.sh"; [[ -x "$frontend_launcher" ]] || frontend_launcher="$root/start-swarm.sh"
  backend_launcher="$root/start-comfyswarm.sh"; [[ -x "$backend_launcher" ]] || backend_launcher="$root/start-image.sh"
  [[ ! -x "$frontend_launcher" ]] || { SWARM_FRONTEND_ONLY=1 bash "$frontend_launcher" --stop || SWARM_FRONTEND_ONLY=1 bash "$frontend_launcher" --kill || fail 'SwarmUI shutdown failed.'; }
  [[ ! -x "$backend_launcher" ]] || { COMFY_BACKEND_ONLY=1 bash "$backend_launcher" --stop || COMFY_BACKEND_ONLY=1 bash "$backend_launcher" --kill || fail 'ComfyUI shutdown failed.'; }
 done
 for i in "${!workload_pids[@]}"; do
  pid=${workload_pids[i]}
  if [[ $(process_token "$pid" || true) == "${workload_tokens[i]}" ]]; then kill -TERM "$pid" || fail "Could not stop PID $pid"; fi
 done
 for ((attempt=0; attempt<100; attempt++)); do
  alive=false
  for i in "${!workload_pids[@]}"; do
   [[ $(process_token "${workload_pids[i]}" || true) != "${workload_tokens[i]}" ]] || alive=true
  done
  [[ "$alive" == true ]] || break
  sleep .2
 done
 for i in "${!workload_pids[@]}"; do
  pid=${workload_pids[i]}
  if [[ $(process_token "$pid" || true) == "${workload_tokens[i]}" ]]; then
   printf '\nForce-stopping GPU workload PID %s.\n' "$pid"
   kill -KILL "$pid" || fail "Could not force-stop PID $pid"
  fi
 done
fi
if ((${#missing[@]})); then
 if ((EUID!=0)); then sudo -n true || fail 'Administrator authorization expired; retry before proceeding.'; admin=(sudo -n); fi
 "${admin[@]}" apt-get update
 DEBIAN_FRONTEND=noninteractive "${admin[@]}" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y "${missing[@]}"
fi
if [[ "$need_uv" == true ]]; then
 temp=$(mktemp); curl -fLsS https://astral.sh/uv/install.sh -o "$temp"; sh "$temp"; rm -f "$temp"
fi
command -v uv >/dev/null || fail 'uv unavailable.'
[[ "$need_python" == false ]] || uv python install 3.12
for url in https://github.com/Comfy-Org/ComfyUI https://huggingface.co https://download.pytorch.org/whl/cu128/; do
 curl -fLsS --max-time 45 -o /dev/null "$url" || fail "Cannot reach $url"
done
# Hold the original directory locks through rename or repair.
if [[ -n "$existing" ]]; then
 exec 9>"$existing/.swarm-session.lock"; exec 8>"$existing/.image-session.lock"
 flock -w 10 9 || fail 'SwarmUI remains active.'
 flock -w 10 8 || fail 'ComfyUI remains active.'
fi
for ((attempt=0; attempt<25; attempt++)); do
 remaining=$(nvidia-smi -i "$gpu" --query-compute-apps=pid --format=csv,noheader,nounits) || fail 'Cannot recheck GPU workloads.'
 [[ "$remaining" =~ [0-9] ]] || break
 sleep .2
done
[[ ! "$remaining" =~ [0-9] ]] || fail 'A GPU workload remains or restarted. Stop its supervisor and retry.'
available=$(nvidia-smi -i "$gpu" --query-gpu=memory.free --format=csv,noheader,nounits); available=${available//[[:space:]]/}
[[ "$available" =~ ^[0-9]+$ ]] && ((available>=8192)) || fail 'Less than 8 GiB GPU memory is free after shutdown.'
if [[ "$fresh_install" == true ]]; then
 backup_dest="${existing%/}.old-$(date +%Y-%m-%d_%H-%M-%S)"
 [[ ! -e "$backup_dest" && ! -L "$backup_dest" ]] || fail 'Backup destination already exists.'
 mv -- "$existing" "$backup_dest" || fail 'Could not rename installation.'
 backup_paths+=("$backup_dest")
 backup_size=$(du -sh -- "$backup_dest" 2>/dev/null | cut -f1) || backup_size='unknown'
 backup_sizes+=("${backup_size:-unknown}")
 printf '\nPrevious installation retained at: %s\n' "$backup_dest"
 flock -u 8; exec 8>&-; flock -u 9; exec 9>&-
fi
if [[ "$resume" == false ]]; then mkdir -p "$(dirname "$dest")"; git clone https://github.com/Comfy-Org/ComfyUI.git "$dest"; fi
cd "$dest"
git rev-parse HEAD > IMAGE_INSTALLED_COMMIT.txt
uv venv --python 3.12 --managed-python .venv --allow-existing
uv pip install --python .venv/bin/python torch==2.10.0 torchvision==0.25.0 --index-url https://download.pytorch.org/whl/cu128
printf 'torch==2.10.0+cu128\ntorchvision==0.25.0+cu128\n' > image-helper-constraints.txt
uv pip install --python .venv/bin/python -r requirements.txt -c image-helper-constraints.txt huggingface-hub
CUDA_VISIBLE_DEVICES="$gpu" .venv/bin/python - <<'GPU'
import torch
assert torch.cuda.is_available(), 'CUDA unavailable in isolated environment.'
assert torch.cuda.get_device_capability(0)>=(7,5), 'Turing or newer required.'
x=torch.ones((64,64),device='cuda',dtype=torch.float16)
assert torch.isfinite(x@x).all().item(), 'GPU FP16 runtime test failed.'
print('GPU computation verified:',torch.cuda.get_device_name(0))
GPU
mkdir -p models/checkpoints workflows
.venv/bin/python - <<'MODEL'
from huggingface_hub import hf_hub_download
from safetensors import safe_open
from pathlib import Path
import shutil,time
repo='cagliostrolab/animagine-xl-4.0'; name='animagine-xl-4.0-opt.safetensors'
p=Path('models/checkpoints')/name
valid=False
if p.exists():
 try:
  with safe_open(p,framework='pt',device='cpu') as f: valid=bool(list(f.keys()))
 except Exception: pass
if not valid:
 if p.exists(): p.rename(p.with_name(p.name+'.damaged.'+str(time.time_ns())))
 hf_hub_download(repo_id=repo,filename=name,local_dir=str(p.parent),force_download=True)
 with safe_open(p,framework='pt',device='cpu') as f: assert list(f.keys()), 'Empty model'
print('Illustration checkpoint verified:',p)
MODEL

if [[ -f .comfyswarm-backend.sh ]]; then cp -p .comfyswarm-backend.sh .comfyswarm-backend.sh.backup.$(date +%Y%m%d-%H%M%S); fi


if [[ -f generate-image-test.py ]]; then cp -p generate-image-test.py generate-image-test.py.backup.$(date +%Y%m%d-%H%M%S); fi
cat > generate-image-test.py <<'SMOKETEST'
#!/usr/bin/env python3
"""Queue the included API workflow and verify a generated PNG."""
import json,os,time,sys,urllib.request,urllib.error
from pathlib import Path
from PIL import Image,ImageStat
port=int(os.environ.get('IMAGE_PORT','8188'))
base=f'http://127.0.0.1:{port}'
def get(path):
 with urllib.request.urlopen(base+path,timeout=15) as r:return json.load(r)
print('Waiting for ComfyUI to initialize...',flush=True)
for _ in range(120):
 try:get('/system_stats');break
 except (OSError,ValueError):time.sleep(2)
else:sys.exit('Server did not become ready. Check .comfyswarm-backend.sh --logs.')
workflow=json.loads(Path('workflows/comfyui-starter-api.json').read_text())
req=urllib.request.Request(base+'/prompt',data=json.dumps({'prompt':workflow}).encode(),headers={'Content-Type':'application/json'})
with urllib.request.urlopen(req,timeout=30) as r:result=json.load(r)
if result.get('node_errors'):sys.exit('Workflow rejected: '+str(result['node_errors']))
pid=result['prompt_id'];print('First image queued. Model loading may take a while.',flush=True)
for _ in range(300):
 history=get('/history/'+pid).get(pid,{})
 if history.get('status',{}).get('status_str')=='error':sys.exit('Generation failed: '+str(history['status'].get('messages')))
 images=[im for out in history.get('outputs',{}).values() for im in out.get('images',[])]
 if images:
  im=images[0];directory=Path('output').resolve();p=(directory/im.get('subfolder','')/im['filename']).resolve()
  if directory not in p.parents:sys.exit('Unexpected output path.')
  with Image.open(p) as image:
   image.load();assert image.size==(1024,1024),'Unexpected image dimensions'
   assert max(ImageStat.Stat(image.convert('RGB')).stddev)>1,'Image appears blank; try --fp32.'
  print('SUCCESS: nonblank 1024 x 1024 PNG generated:',p)
  print('Open the matching result in the ComfyUI browser.');break
 time.sleep(2)
else:sys.exit('Generation timed out; inspect logs before submitting another job.')
SMOKETEST

if [[ -f workflows/comfyui-starter.json ]]; then cp -p workflows/comfyui-starter.json workflows/comfyui-starter.json.backup.$(date +%Y%m%d-%H%M%S); fi
cat > workflows/comfyui-starter.json <<'UIWORKFLOW'
{
  "last_node_id": 7,
  "last_link_id": 9,
  "nodes": [
    {
      "id": 1,
      "type": "CheckpointLoaderSimple",
      "pos": [
        400,
        40
      ],
      "size": [
        320,
        260
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            3
          ],
          "slot_index": 0
        },
        {
          "name": "CLIP",
          "type": "CLIP",
          "links": [
            1,
            2
          ],
          "slot_index": 1
        },
        {
          "name": "VAE",
          "type": "VAE",
          "links": [
            8
          ],
          "slot_index": 2
        }
      ],
      "properties": {
        "Node name for S&R": "CheckpointLoaderSimple"
      },
      "widgets_values": [
        "animagine-xl-4.0-opt.safetensors"
      ]
    },
    {
      "id": 2,
      "type": "CLIPTextEncode",
      "pos": [
        760,
        40
      ],
      "size": [
        320,
        260
      ],
      "flags": {},
      "order": 1,
      "mode": 0,
      "inputs": [
        {
          "name": "clip",
          "type": "CLIP",
          "link": 1
        }
      ],
      "outputs": [
        {
          "name": "CONDITIONING",
          "type": "CONDITIONING",
          "links": [
            4
          ],
          "slot_index": 0
        }
      ],
      "properties": {
        "Node name for S&R": "CLIPTextEncode"
      },
      "widgets_values": [
        "1girl, adult, original character, short dark hair, practical science fiction jacket, standing, three-quarter view, monochrome, manga, lineart, white background, clean outlines, minimal shading, character design, safe, masterpiece, high score, great score"
      ]
    },
    {
      "id": 3,
      "type": "CLIPTextEncode",
      "pos": [
        40,
        380
      ],
      "size": [
        320,
        260
      ],
      "flags": {},
      "order": 2,
      "mode": 0,
      "inputs": [
        {
          "name": "clip",
          "type": "CLIP",
          "link": 2
        }
      ],
      "outputs": [
        {
          "name": "CONDITIONING",
          "type": "CONDITIONING",
          "links": [
            5
          ],
          "slot_index": 0
        }
      ],
      "properties": {
        "Node name for S&R": "CLIPTextEncode"
      },
      "widgets_values": [
        "lowres, bad anatomy, bad hands, extra digits, missing fingers, text, speech bubble, watermark, signature, blurry, photorealistic, heavy shading"
      ]
    },
    {
      "id": 4,
      "type": "EmptyLatentImage",
      "pos": [
        400,
        380
      ],
      "size": [
        320,
        260
      ],
      "flags": {},
      "order": 3,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "LATENT",
          "type": "LATENT",
          "links": [
            6
          ],
          "slot_index": 0
        }
      ],
      "properties": {
        "Node name for S&R": "EmptyLatentImage"
      },
      "widgets_values": [
        1024,
        1024,
        1
      ]
    },
    {
      "id": 5,
      "type": "KSampler",
      "pos": [
        760,
        380
      ],
      "size": [
        320,
        260
      ],
      "flags": {},
      "order": 4,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 3
        },
        {
          "name": "positive",
          "type": "CONDITIONING",
          "link": 4
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "link": 5
        },
        {
          "name": "latent_image",
          "type": "LATENT",
          "link": 6
        }
      ],
      "outputs": [
        {
          "name": "LATENT",
          "type": "LATENT",
          "links": [
            7
          ],
          "slot_index": 0
        }
      ],
      "properties": {
        "Node name for S&R": "KSampler"
      },
      "widgets_values": [
        123456,
        "fixed",
        28,
        5,
        "euler_ancestral",
        "normal",
        1
      ]
    },
    {
      "id": 6,
      "type": "VAEDecode",
      "pos": [
        40,
        720
      ],
      "size": [
        320,
        260
      ],
      "flags": {},
      "order": 5,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": 7
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 8
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            9
          ],
          "slot_index": 0
        }
      ],
      "properties": {
        "Node name for S&R": "VAEDecode"
      },
      "widgets_values": []
    },
    {
      "id": 7,
      "type": "SaveImage",
      "pos": [
        400,
        720
      ],
      "size": [
        320,
        260
      ],
      "flags": {},
      "order": 6,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 9
        }
      ],
      "outputs": [],
      "properties": {
        "Node name for S&R": "SaveImage"
      },
      "widgets_values": [
        "ComfyUI_test"
      ]
    }
  ],
  "links": [
    [
      1,
      1,
      1,
      2,
      0,
      "CLIP"
    ],
    [
      2,
      1,
      1,
      3,
      0,
      "CLIP"
    ],
    [
      3,
      1,
      0,
      5,
      0,
      "MODEL"
    ],
    [
      4,
      2,
      0,
      5,
      1,
      "CONDITIONING"
    ],
    [
      5,
      3,
      0,
      5,
      2,
      "CONDITIONING"
    ],
    [
      6,
      4,
      0,
      5,
      3,
      "LATENT"
    ],
    [
      7,
      5,
      0,
      6,
      0,
      "LATENT"
    ],
    [
      8,
      1,
      2,
      6,
      1,
      "VAE"
    ],
    [
      9,
      6,
      0,
      7,
      0,
      "IMAGE"
    ]
  ],
  "groups": [],
  "config": {},
  "extra": {},
  "version": 0.4
}
UIWORKFLOW

if [[ -f workflows/comfyui-starter-api.json ]]; then cp -p workflows/comfyui-starter-api.json workflows/comfyui-starter-api.json.backup.$(date +%Y%m%d-%H%M%S); fi
cat > workflows/comfyui-starter-api.json <<'APIWORKFLOW'
{
  "1": {
    "class_type": "CheckpointLoaderSimple",
    "inputs": {
      "ckpt_name": "animagine-xl-4.0-opt.safetensors"
    }
  },
  "2": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "1girl, adult, original character, short dark hair, practical science fiction jacket, standing, three-quarter view, monochrome, manga, lineart, white background, clean outlines, minimal shading, character design, safe, masterpiece, high score, great score",
      "clip": [
        "1",
        1
      ]
    }
  },
  "3": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "lowres, bad anatomy, bad hands, extra digits, missing fingers, text, speech bubble, watermark, signature, blurry, photorealistic, heavy shading",
      "clip": [
        "1",
        1
      ]
    }
  },
  "4": {
    "class_type": "EmptyLatentImage",
    "inputs": {
      "width": 1024,
      "height": 1024,
      "batch_size": 1
    }
  },
  "5": {
    "class_type": "KSampler",
    "inputs": {
      "seed": 123456,
      "steps": 28,
      "cfg": 5,
      "sampler_name": "euler_ancestral",
      "scheduler": "normal",
      "denoise": 1,
      "model": [
        "1",
        0
      ],
      "positive": [
        "2",
        0
      ],
      "negative": [
        "3",
        0
      ],
      "latent_image": [
        "4",
        0
      ]
    }
  },
  "6": {
    "class_type": "VAEDecode",
    "inputs": {
      "samples": [
        "5",
        0
      ],
      "vae": [
        "1",
        2
      ]
    }
  },
  "7": {
    "class_type": "SaveImage",
    "inputs": {
      "images": [
        "6",
        0
      ],
      "filename_prefix": "ComfyUI_test"
    }
  }
}
APIWORKFLOW

# SwarmUI frontend: separate CPU application, shared model directory.
swarm="$dest/SwarmUI"
if [[ ! -d "$swarm" ]]; then
 git clone https://github.com/mcmonkeyprojects/SwarmUI.git "$swarm"
else
 [[ "$(git -C "$swarm" remote get-url origin)" == https://github.com/mcmonkeyprojects/SwarmUI.git ]] || fail 'Unexpected SwarmUI checkout.'
 # Preserve local changes; only advance a clean checkout by fast-forward.
 if [[ -z "$(git -C "$swarm" status --porcelain --untracked-files=no)" ]]; then
  git -C "$swarm" pull --ff-only
 else
  printf '\nSwarmUI has local source changes; building current checkout.\n'
 fi
fi
if [[ ! -x "$swarm/.dotnet/dotnet" ]]; then
 [[ "$need_dotnet" == true ]] || fail '.NET prerequisite was not approved.'
 curl -fLsS https://dot.net/v1/dotnet-install.sh -o "$swarm/dotnet-install-helper.sh"
 bash "$swarm/dotnet-install-helper.sh" --channel 8.0 --install-dir "$swarm/.dotnet"
 bash "$swarm/dotnet-install-helper.sh" --channel 8.0 --runtime aspnetcore --install-dir "$swarm/.dotnet"
fi
export DOTNET_ROOT="$swarm/.dotnet"
"$DOTNET_ROOT/dotnet" --info
"$DOTNET_ROOT/dotnet" build "$swarm/src/SwarmUI.csproj" --configuration Release -o "$swarm/src/bin/live_release"
[[ -s "$swarm/src/bin/live_release/SwarmUI.dll" ]] || fail 'SwarmUI build is incomplete.'
mkdir -p "$swarm/Data" custom_nodes
# Swarm-required nodes live inside its checkout; no duplicate model downloads.
for nodes in ExtraNodes DLNodes; do
 node_source="$swarm/src/BuiltinExtensions/ComfyUIBackend/$nodes"
 [[ "$nodes" != DLNodes ]] || mkdir -p "$node_source"
 [[ -d "$node_source" ]] || fail "Missing SwarmUI node directory: $node_source"
 link="$dest/custom_nodes/SwarmUI_$nodes"
 if [[ -e "$link" || -L "$link" ]]; then
  [[ -L "$link" && "$(readlink "$link")" == "$node_source" ]] || fail "Node path conflict: $link"
 else
  ln -s "$node_source" "$link"
 fi
 if [[ -f "$node_source/requirements.txt" ]]; then
  uv pip install --python .venv/bin/python -r "$node_source/requirements.txt" -c image-helper-constraints.txt
 fi
done
if [[ ! -f "$swarm/Data/Settings.fds" ]]; then
 cat > "$swarm/Data/Settings.fds" <<SWARMSETTINGS
IsInstalled: true
LaunchMode: none
Paths:
    ModelRoot: $dest/models
    SDModelFolder: checkpoints
    SDLoraFolder: loras
    SDVAEFolder: vae
    SDEmbeddingFolder: embeddings
Network:
    Host: 127.0.0.1
    Port: 7801
    PortCanChange: false
SWARMSETTINGS
fi
if [[ ! -f "$swarm/Data/Backends.fds" ]]; then
 cat > "$swarm/Data/Backends.fds" <<'SWARMBACKEND'
0:
    type: comfyui_api
    enabled: true
    title: Local ComfyUI
    settings:
        Address: http://127.0.0.1:8188
        AllowIdle: true
SWARMBACKEND
fi
chmod 600 "$swarm/Data/Settings.fds" "$swarm/Data/Backends.fds"
cat > start-comfyswarm.sh <<'SWARMLAUNCHER'
#!/usr/bin/env bash
# SwarmUI browser launcher; Ubuntu/Linux, Bash. No environment activation required.
set -Eeuo pipefail
# Only the public invocation reports backups; internal service calls stay quiet.
if [[ ${COMFY_BACKEND_ONLY:-0} != 1 && ${SWARM_FRONTEND_ONLY:-0} != 1 ]]; then
backup_paths=(); backup_sizes=()
collect_install_backups(){
 local install_dir=${1%/} candidate size
 local parent=${install_dir%/*} base=${install_dir##*/}
 for candidate in "$parent/$base.old"*; do
  [[ -d "$candidate" && ! -L "$candidate" ]] || continue
  size=$(du -sh -- "$candidate" 2>/dev/null | cut -f1) || size='unknown'
  backup_paths+=("$candidate"); backup_sizes+=("${size:-unknown}")
 done
}
print_backup_reminder(){
 ((${#backup_paths[@]})) || return 0
 printf '\nPrevious installation backups (disk usage measured when this command began):\n'
 local index
 for index in "${!backup_paths[@]}"; do
  printf '  %s  %s\n' "${backup_sizes[index]}" "${backup_paths[index]}"
 done
 printf '\nInspect these directories and keep any files you need.\n'
 printf 'When you are sure they are no longer needed, delete them manually to recover disk space.\n'
 printf 'This script does not delete backups.\n\n'
}
 launcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
 collect_install_backups "$launcher_dir"
 case "${launcher_dir##*/}" in
  ComfySwarmUI) collect_install_backups "${launcher_dir%/*}/ComfyUI" ;;
  ComfyUI) collect_install_backups "${launcher_dir%/*}/ComfySwarmUI" ;;
 esac
 trap 'print_backup_reminder' EXIT
fi
if [[ ${COMFY_BACKEND_ONLY:-0} == 1 ]]; then
 export COMFYSWARM_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
 bash -s -- "$@" <<'COMFYINTERNAL'
#!/usr/bin/env bash
# ComfyUI image launcher; Ubuntu/Linux, Bash. No environment activation required.
set -Eeuo pipefail
# Indent both streams; preserve progress output while flushing each line.
output_sync_dir=$(mktemp -d)
format_output() {
    awk -v ack="$1" '
        $0 == "__HELPER_OUTPUT_BARRIER__" { print "ready" > ack; close(ack); next }
        { print " " $0; fflush() }
    '
}
exec > >(format_output "$output_sync_dir/stdout") 2> >(format_output "$output_sync_dir/stderr" >&2)
sync_output() {
    rm -f "$output_sync_dir/stdout" "$output_sync_dir/stderr"
    printf '__HELPER_OUTPUT_BARRIER__\n'
    printf '__HELPER_OUTPUT_BARRIER__\n' >&2
    local attempt
    for ((attempt=0; attempt<500; attempt++)); do
        if [[ -f "$output_sync_dir/stdout" && -f "$output_sync_dir/stderr" ]]; then return 0; fi
        sleep 0.01
    done
    printf 'Output flush timed out; prompt cancelled.\n' >&2
    return 1
}
printf '\n\n'
child=''
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n "$child" ]]; then kill -TERM -- "-$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
    if [[ "${owns_lock:-false}" == true ]]; then rm -f -- "$session"; fi
    printf '\n\n'
    sync_output || true
    rm -rf -- "$output_sync_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "\nError at line %s; startup stopped.\n" "$LINENO" >&2' ERR
fail() { printf '\n%s\n' "$*" >&2; exit 1; }
usage() {
cat <<'HELP'
Usage: start-image [--local|--lan] [--auto|--fp16|--fp32]
                   [--gpu INDEX] [--port NUMBER] [--foreground|--background]
                   [--non-interactive] [--status|--logs|--stop|--kill] [--help]

Default: ask for LAN access [no], then launch in background.
ComfyUI has no built-in browser login in this helper. Localhost with SSH
forwarding is the default; LAN access is unprotected unless you add a proxy.
Auto uses FP16 for the image model and FP32 for the VAE on Turing/newer.
Includes Animagine XL 4.0 Opt and a starter workflow.
HELP
}
export IMAGE_DTYPE="${IMAGE_DTYPE:-auto}"
export IMAGE_MODEL=animagine-xl-4.0-opt.safetensors
export IMAGE_PORT="${IMAGE_PORT:-8188}"
gpu="${IMAGE_GPU_INDEX:-0}"
bind=127.0.0.1
access_mode=ask
foreground=false
non_interactive=false
action=start
while (( $# )); do
 case "$1" in
  --help|-h) usage; exit 0 ;;
  --status|--logs|--stop|--kill) action="${1#--}"; shift ;;
  --local) access_mode=local; bind=127.0.0.1; shift ;;
  --lan) access_mode=lan; bind=0.0.0.0; shift ;;
  --foreground) foreground=true; shift ;;
  --background) foreground=false; shift ;;
  --non-interactive) non_interactive=true; shift ;;
  --auto) export IMAGE_DTYPE=auto; shift ;;
  --fp16) export IMAGE_DTYPE=float16; shift ;;
  --fp32) export IMAGE_DTYPE=float32; shift ;;
  --gpu|--port)
   (( $# >= 2 )) || fail "Missing value for $1"
   if [[ "$1" == --gpu ]]; then gpu="$2"; else export IMAGE_PORT="$2"; fi
   shift 2 ;;
  *) fail "Unknown option: $1. Use --help." ;;
 esac
done
if [[ "$action" != start ]]; then
    cd -- "$COMFYSWARM_ROOT"
    if [[ "$action" == logs ]]; then
        [[ -f image-server.log ]] || fail 'No background server log exists yet.'
        tail -n 80 image-server.log
        exit 0
    fi
    [[ -x .venv/bin/python ]] || fail 'ComfyUI Python environment is missing.'
    .venv/bin/python - "$action" <<'MANAGE'
import json, os, signal, sys, time, socket
from pathlib import Path
p=Path('.image-server.json')
def identity(pid):
    try:
        text=Path(f'/proc/{pid}/stat').read_text()
        fields=text.rsplit(')',1)[1].split()
        return fields[19], fields[0]
    except (OSError,IndexError): return None,None
if not p.exists():
    print('No managed background server is recorded. A legacy foreground session may still be running.')
    sys.exit(0)
try: info=json.loads(p.read_text()); pid=int(info['pid'])
except (ValueError,KeyError): sys.exit('Invalid server metadata; no process was signalled.')
token,state=identity(pid)
if token!=info['start_token'] or state=='Z':
    print('Recorded server is no longer active; metadata is stale. No process was signalled.')
    sys.exit(0)
if os.getpgid(pid)!=pid or info['directory']!=str(Path.cwd()):
    sys.exit('Process identity/group check failed; no process was signalled.')
if sys.argv[1]=='status':
    print(f"ComfyUI process is running (PID {pid}, port {info['port']}, model {info['model']}).")
    print('This confirms the process, not model initialization or HTTP readiness.')
    sys.exit(0)
sig=signal.SIGKILL if sys.argv[1]=='kill' else signal.SIGTERM
os.killpg(pid,sig)
def group_alive():
    for proc in Path('/proc').glob('[0-9]*/stat'):
        try:
            fields=proc.read_text().rsplit(')',1)[1].split()
            if int(fields[2])==pid and fields[0]!='Z': return True
        except (OSError,ValueError,IndexError): pass
    return False
def port_available():
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        try: sock.bind(('0.0.0.0',int(info['port']))); return True
        except OSError: return False
for _ in range(150):
    if not group_alive() and port_available(): break
    time.sleep(.2)
else: sys.exit('Shutdown is still pending or the port has another listener. Inspect --status/--logs and the port owner before retrying.')
print('ComfyUI process group stopped and its port is available.')
p.unlink(missing_ok=True)
Path('.image-session.info').unlink(missing_ok=True)

MANAGE
    exit 0
fi
[[ "$gpu" =~ ^[0-9]+$ ]] || fail 'GPU index must be numeric.'
[[ "$IMAGE_PORT" =~ ^[0-9]+$ ]] && (( IMAGE_PORT>=1 && IMAGE_PORT<=65535 )) || fail 'Invalid port.'
if [[ "$non_interactive" == true && "$access_mode" == ask ]]; then
 fail 'Non-interactive startup requires --local or --lan.'
fi
if [[ "$access_mode" == ask ]]; then
    [[ -r /dev/tty ]] || fail 'Specify --local or --lan when no interactive terminal is available.'
    while true; do
        sync_output
        printf '\n Allow LAN browser access? [y/N]: ' >/dev/tty
        read -r access_answer </dev/tty || fail 'LAN selection cancelled.'
        case "$access_answer" in
            y|Y|yes|YES) bind=0.0.0.0; break ;;
            ''|n|N|no|NO) bind=127.0.0.1; break ;;
            *) printf ' Please answer yes or no.\n' >/dev/tty ;;
        esac
    done
fi
cd -- "$COMFYSWARM_ROOT"
export PATH="$HOME/.local/bin:$PATH"
command -v flock >/dev/null || fail 'flock is unavailable (Ubuntu util-linux package).'
command -v setsid >/dev/null || fail 'setsid is unavailable (Ubuntu util-linux package).'
[[ -f main.py && -x .venv/bin/python ]] || fail 'Incomplete ComfyUI installation. Run the installer to repair it.'
[[ -s "models/checkpoints/$IMAGE_MODEL" ]] || fail 'Image model is missing; repair the installation.'

# flock is authoritative: kernel releases it on a crash. Never unlink its
# inode, which could allow competing processes to lock different files.
lock="$PWD/.image-session.lock"
session="$PWD/.image-session.info"
exec 9>"$lock"
if ! flock -n 9; then
    printf '\nComfyUI already has an active launcher session.\n'
    [[ ! -f "$session" ]] || cat "$session"
    exit 1
fi
owns_lock=true
if [[ -f "$session" ]]; then
    printf '\nRecovered stale session metadata; the kernel lock is free.\n'
    cat "$session"
fi
# Detect a listener even if it was started without this launcher.
IMAGE_BIND="$bind" .venv/bin/python - <<'PORTCHECK'
import os,socket,time
# Match the HTTP server’s reuse-address behavior: TCP TIME_WAIT after a
# shutdown must not be mistaken for a live listener.
for attempt in range(51):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        try:
            sock.bind((os.environ['IMAGE_BIND'],int(os.environ['IMAGE_PORT'])))
            break
        except OSError as e:
            if attempt==50: raise SystemExit(f'Port is unavailable: {e}. Inspect its owner or choose --port.')
    if attempt==0: print('Waiting briefly for the previous listener to release the port...',flush=True)
    time.sleep(.2)

PORTCHECK
printf 'Launcher PID: %s\nStarted: %s\nGPU: %s\nModel: %s\nPort: %s\n' "$$" "$(date -Is)" "$gpu" "$IMAGE_MODEL" "$IMAGE_PORT" > "$session"
chmod 600 "$session"
export CUDA_VISIBLE_DEVICES="$gpu"
export IMAGE_BIND="$bind"
if [[ "$bind" != 127.0.0.1 ]]; then
    printf '\nBrowser: http://<host-LAN-IP>:%s\n\n' "$IMAGE_PORT"
else
    printf '\nBrowser: http://127.0.0.1:%s (local or SSH tunnel)\n\n' "$IMAGE_PORT"
fi
log="$PWD/image-server.log"
if [[ "$foreground" == false ]]; then
    printf '\nStarting ComfyUI in background. Log: %s\n' "$log"
    # Protect potentially sensitive user prompts/lyrics written by ComfyUI logs.
    (umask 077; touch "$log")
    chmod 600 "$log"
fi
# Child inherits the kernel lock: even if launcher dies, a surviving server
# prevents another launcher from starting. Supervisor cleans metadata on exit.
# A detached session survives SSH disconnection; redirect output away from terminal.
# Foreground mode uses the same process group, supervised by this shell.
if [[ "$foreground" == true ]]; then exec 7>&1; else exec 7>>"$log"; fi
setsid .venv/bin/python - >&7 2>&1 <<'PYIMAGE' &
import os,runpy,sys
import torch
if not torch.cuda.is_available(): raise SystemExit('CUDA unavailable; check NVIDIA driver.')
cap=torch.cuda.get_device_capability(0)
if cap<(7,5): raise SystemExit('This helper targets Turing or newer GPUs.')
dtype=os.environ['IMAGE_DTYPE']
if dtype=='auto': dtype='float16'
if dtype not in ('float16','float32'): raise SystemExit('IMAGE_DTYPE must be auto, float16, or float32.')
print(f'GPU: {torch.cuda.get_device_name(0)}; image-model precision: {dtype}; VAE: FP32',flush=True)
sys.argv=['main.py','--listen',os.environ['IMAGE_BIND'],'--port',os.environ['IMAGE_PORT'],
 '--disable-auto-launch','--fp32-vae','--use-pytorch-cross-attention']
sys.argv+=['--fp16-unet','--fp16-text-enc'] if dtype=='float16' else ['--force-fp32']
runpy.run_path('main.py',run_name='__main__')

PYIMAGE
child=$!
printf 'Server process: %s\n' "$child" >> "$session"
# Record Linux process start time to prevent signalling a recycled PID.
.venv/bin/python - "$child" <<'RECORD'
import json,os,sys,time
from pathlib import Path
pid=int(sys.argv[1])
for _ in range(100):
    try:
        fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
        if os.getpgid(pid)==pid: break
    except OSError: pass
    time.sleep(.02)
else: raise SystemExit('Server exited before its process identity could be recorded. Check image-server.log.')
info={'pid':pid,'start_token':fields[19], 'directory':str(Path.cwd()),
      'port':os.environ['IMAGE_PORT'],'model':os.environ['IMAGE_MODEL']}
p=Path('.image-server.json');tmp=p.with_suffix('.tmp')
tmp.write_text(json.dumps(info));tmp.chmod(0o600);tmp.replace(p)
RECORD
if [[ "$foreground" == false ]]; then
    # Child now owns the inherited lock. Parent exits without stopping it.
    child=''
    owns_lock=false
    exec 9>&-
    exec 7>&-
    printf '\nComfyUI launched. Initialization continues in the background.\n'
    if [[ ${STACK_CHILD:-0} != 1 ]]; then
     printf 'Status: start-comfyswarm --status\nLogs: start-comfyswarm --logs --service comfyui\nStop: start-comfyswarm --stop\n'
    fi
    exit 0
fi
wait "$child"
child=''

COMFYINTERNAL
 exit $?
fi
# Coordinate the stack; inner mode retains each service's identity-checked lifecycle.
if [[ ${SWARM_FRONTEND_ONLY:-0} != 1 ]]; then
 root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
 action=start
 service=all
 args=()
 while (($#)); do
  if [[ "$1" == --service ]]; then
   (($#>=2)) || { printf ' --service needs comfyui or swarmui.\n' >&2; exit 1; }
   service="$2"; shift 2; continue
  fi
  args+=("$1"); shift
 done
 [[ "$service" == all || "$service" == comfyui || "$service" == swarmui ]] || { printf ' Invalid service. Use comfyui or swarmui.\n' >&2; exit 1; }
 set -- "${args[@]}"
 for arg in "$@"; do
  case "$arg" in --help|-h) action=help;; --status) action=status;; --logs) action=logs;; --stop) action=stop;; --kill) action=kill;; --restart) action=restart;; --foreground) printf '\n Foreground mode is not supported by the stack launcher; use --logs.\n\n' >&2; exit 1;; esac
 done
 if [[ "$action" == help ]]; then
  printf '\n Usage: start-comfyswarm [--local|--lan] [--non-interactive] [--gpu INDEX]\n'
  printf '                     [--auto|--fp16|--fp32] [--port PORT] [--background]\n'
  printf '                     [--status|--logs|--stop|--kill|--restart|--help] [--service comfyui|swarmui]\n\n'
  printf ' Starts ComfyUI first, then SwarmUI. Stops SwarmUI first, then ComfyUI.\n'
  printf ' Local-only access is the default; LAN access has no login protection.\n'
  printf ' --port changes the SwarmUI port; ComfyUI remains on port 8188.\n\n'
  exit 0
 fi
 command -v flock >/dev/null || { printf ' flock is required.\n' >&2; exit 1; }
 exec 6>"$root/.image-stack-control.lock"
 flock -w 15 6 || { printf ' Another stack operation is in progress.\n' >&2; exit 1; }
 frontend(){ STACK_CHILD=1 SWARM_FRONTEND_ONLY=1 bash "$root/start-comfyswarm.sh" "$@" 6>&-; }
 backend(){ STACK_CHILD=1 COMFY_BACKEND_ONLY=1 bash "$root/start-comfyswarm.sh" "$@" 6>&-; }
 if [[ "$action" == logs && "$service" == all ]]; then
  printf '\n Choose logs with --logs --service comfyui or --logs --service swarmui.\n\n' >&2; exit 1
 fi
 if [[ "$action" == restart ]]; then
  if [[ "$service" != comfyui ]]; then frontend --stop || frontend --kill || exit 1; fi
  if [[ "$service" != swarmui ]]; then backend --stop || backend --kill || exit 1; fi
  cleaned=(); for arg in "$@"; do [[ "$arg" == --restart ]] || cleaned+=("$arg"); done
  set -- "${cleaned[@]}"; action=start
 fi
 if [[ "$service" != all ]]; then
  if [[ "$service" == comfyui ]]; then backend "$@"; else frontend "$@"; fi
  exit $?
 fi
 if [[ "$action" == status || "$action" == logs ]]; then
  printf '\n SwarmUI frontend:\n'; frontend "--$action"
  printf '\n ComfyUI backend:\n'; backend "--$action"
  exit 0
 fi
 if [[ "$action" == stop || "$action" == kill ]]; then
  printf '\n Stopping SwarmUI first...\n'
  frontend "--$action" || { printf ' SwarmUI did not stop; ComfyUI has been left running.\n' >&2; exit 1; }
  printf '\n Stopping ComfyUI backend...\n'
  backend "--$action" || exit 1
  printf '\n Stack shutdown complete.\n\n'
  exit 0
 fi
 # A managed live frontend should be reused rather than launched twice.
 active=false
 if "$root/.venv/bin/python" - "$root" <<'STACKIDENTITY'
import json,os,sys
from pathlib import Path
try:
 root=Path(sys.argv[1]);r=json.loads((root/'.swarm-server.json').read_text());pid=int(r['pid'])
 fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
 assert fields[19]==r['start_token'] and fields[0]!='Z' and os.getpgid(pid)==pid and r['directory']==str(root)
except Exception: sys.exit(1)
STACKIDENTITY
 then active=true; fi
 if [[ "$active" == true ]]; then
  printf '\n SwarmUI is already running. Checking its ComfyUI dependency...\n'
  if ! "$root/.venv/bin/python" -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8188/system_stats",timeout=3)' >/dev/null 2>&1; then
   backend --local --non-interactive --background || exit 1
  fi
 else
  frontend "$@" || exit 1
 fi
 "$root/.venv/bin/python" - "$root" <<'STACKREADY'
import json,time,urllib.request,sys
from pathlib import Path
root=Path(sys.argv[1]);port=json.loads((root/'.swarm-server.json').read_text())['port']
checks=[('ComfyUI','http://127.0.0.1:8188/system_stats',None),
 ('SwarmUI',f'http://127.0.0.1:{port}/API/GetNewSession',b'{}')]
for name,url,data in checks:
 for attempt in range(120):
  try:
   req=urllib.request.Request(url,data,{'Content-Type':'application/json'})
   with urllib.request.urlopen(req,timeout=2) as response: result=json.load(response)
   if name=='SwarmUI' and 'session_id' not in result: raise RuntimeError('Session unavailable')
   break
  except Exception: time.sleep(1)
 else: sys.exit(f'{name} did not become ready. Inspect start-comfyswarm --logs --service swarmui.')
 print(f' {name}: running and HTTP ready ({url.split("/API")[0].split("/system_stats")[0]}).',flush=True)
print('\n Both services are ready. Use start-comfyswarm --stop to stop the complete stack.\n')
STACKREADY
 exit $?
fi
# Indent both streams; preserve progress output while flushing each line.
output_sync_dir=$(mktemp -d)
format_output() {
    awk -v ack="$1" '
        $0 == "__HELPER_OUTPUT_BARRIER__" { print "ready" > ack; close(ack); next }
        { print " " $0; fflush() }
    '
}
exec > >(format_output "$output_sync_dir/stdout") 2> >(format_output "$output_sync_dir/stderr" >&2)
sync_output() {
    rm -f "$output_sync_dir/stdout" "$output_sync_dir/stderr"
    printf '__HELPER_OUTPUT_BARRIER__\n'
    printf '__HELPER_OUTPUT_BARRIER__\n' >&2
    local attempt
    for ((attempt=0; attempt<500; attempt++)); do
        if [[ -f "$output_sync_dir/stdout" && -f "$output_sync_dir/stderr" ]]; then return 0; fi
        sleep 0.01
    done
    printf 'Output flush timed out; prompt cancelled.\n' >&2
    return 1
}
printf '\n\n'
child=''
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n "$child" ]]; then kill -TERM -- "-$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
    if [[ "${owns_lock:-false}" == true ]]; then rm -f -- "$session"; fi
    printf '\n\n'
    sync_output || true
    rm -rf -- "$output_sync_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "\nError at line %s; startup stopped.\n" "$LINENO" >&2' ERR
fail() { printf '\n%s\n' "$*" >&2; exit 1; }
usage() {
cat <<'HELP'
Usage: start-comfyswarm [--local|--lan] [--auto|--fp16|--fp32]
                   [--gpu INDEX] [--port NUMBER] [--foreground|--background]
                   [--non-interactive] [--status|--logs|--stop|--kill] [--help]

Default: ask for LAN access [no], then launch in background.
ComfyUI has no built-in browser login in this helper. Localhost with SSH
forwarding is the default; LAN access is unprotected unless you add a proxy.
Auto uses FP16 for the image model and FP32 for the VAE on Turing/newer.
SwarmUI uses the installed ComfyUI backend on port 8188.
--stop/--kill stop SwarmUI only; use --service comfyui for backend debugging.
HELP
}
export IMAGE_DTYPE="${IMAGE_DTYPE:-auto}"
export IMAGE_MODEL=animagine-xl-4.0-opt.safetensors
export IMAGE_PORT="${SWARM_PORT:-7801}"
gpu="${IMAGE_GPU_INDEX:-0}"
bind=127.0.0.1
access_mode=ask
foreground=false
non_interactive=false
action=start
while (( $# )); do
 case "$1" in
  --help|-h) usage; exit 0 ;;
  --status|--logs|--stop|--kill) action="${1#--}"; shift ;;
  --local) access_mode=local; bind=127.0.0.1; shift ;;
  --lan) access_mode=lan; bind=0.0.0.0; shift ;;
  --foreground) foreground=true; shift ;;
  --background) foreground=false; shift ;;
  --non-interactive) non_interactive=true; shift ;;
  --auto) export IMAGE_DTYPE=auto; shift ;;
  --fp16) export IMAGE_DTYPE=float16; shift ;;
  --fp32) export IMAGE_DTYPE=float32; shift ;;
  --gpu|--port)
   (( $# >= 2 )) || fail "Missing value for $1"
   if [[ "$1" == --gpu ]]; then gpu="$2"; else export IMAGE_PORT="$2"; fi
   shift 2 ;;
  *) fail "Unknown option: $1. Use --help." ;;
 esac
done
if [[ "$action" != start ]]; then
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    if [[ "$action" == logs ]]; then
        [[ -f swarm-server.log ]] || fail 'No background server log exists yet.'
        tail -n 80 swarm-server.log
        exit 0
    fi
    [[ -x .venv/bin/python ]] || fail 'ComfyUI Python environment is missing.'
    .venv/bin/python - "$action" <<'MANAGE'
import json, os, signal, sys, time, socket
from pathlib import Path
p=Path('.swarm-server.json')
def identity(pid):
    try:
        text=Path(f'/proc/{pid}/stat').read_text()
        fields=text.rsplit(')',1)[1].split()
        return fields[19], fields[0]
    except (OSError,IndexError): return None,None
if not p.exists():
    print('No managed background server is recorded. A legacy foreground session may still be running.')
    sys.exit(0)
try: info=json.loads(p.read_text()); pid=int(info['pid'])
except (ValueError,KeyError): sys.exit('Invalid server metadata; no process was signalled.')
token,state=identity(pid)
if token!=info['start_token'] or state=='Z':
    print('Recorded server is no longer active; metadata is stale. No process was signalled.')
    sys.exit(0)
if os.getpgid(pid)!=pid or info['directory']!=str(Path.cwd()):
    sys.exit('Process identity/group check failed; no process was signalled.')
if sys.argv[1]=='status':
    print(f"SwarmUI process is running (PID {pid}, port {info['port']}, model {info['model']}).")
    print('This confirms the process, not model initialization or HTTP readiness.')
    sys.exit(0)
sig=signal.SIGKILL if sys.argv[1]=='kill' else signal.SIGTERM
os.killpg(pid,sig)
def group_alive():
    for proc in Path('/proc').glob('[0-9]*/stat'):
        try:
            fields=proc.read_text().rsplit(')',1)[1].split()
            if int(fields[2])==pid and fields[0]!='Z': return True
        except (OSError,ValueError,IndexError): pass
    return False
def port_available():
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        try: sock.bind(('0.0.0.0',int(info['port']))); return True
        except OSError: return False
for _ in range(150):
    if not group_alive() and port_available(): break
    time.sleep(.2)
else: sys.exit('Shutdown is still pending or the port has another listener. Inspect --status/--logs and the port owner before retrying.')
print('SwarmUI process group stopped and its port is available.')
p.unlink(missing_ok=True)
Path('.swarm-session.info').unlink(missing_ok=True)

MANAGE
    exit 0
fi
[[ "$gpu" =~ ^[0-9]+$ ]] || fail 'GPU index must be numeric.'
[[ "$IMAGE_PORT" =~ ^[0-9]+$ ]] && (( IMAGE_PORT>=1 && IMAGE_PORT<=65535 )) || fail 'Invalid port.'
if [[ "$non_interactive" == true && "$access_mode" == ask ]]; then
 fail 'Non-interactive startup requires --local or --lan.'
fi
if [[ "$access_mode" == ask ]]; then
    [[ -r /dev/tty ]] || fail 'Specify --local or --lan when no interactive terminal is available.'
    while true; do
        sync_output
        printf '\n Allow LAN browser access? [y/N]: ' >/dev/tty
        read -r access_answer </dev/tty || fail 'LAN selection cancelled.'
        case "$access_answer" in
            y|Y|yes|YES) bind=0.0.0.0; break ;;
            ''|n|N|no|NO) bind=127.0.0.1; break ;;
            *) printf ' Please answer yes or no.\n' >/dev/tty ;;
        esac
    done
fi
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
export PATH="$HOME/.local/bin:$PATH"
command -v flock >/dev/null || fail 'flock is unavailable (Ubuntu util-linux package).'
command -v setsid >/dev/null || fail 'setsid is unavailable (Ubuntu util-linux package).'
[[ -s SwarmUI/src/bin/live_release/SwarmUI.dll && -x SwarmUI/.dotnet/dotnet && -x .venv/bin/python ]] || fail 'Incomplete ComfyUI installation. Run the installer to repair it.'
[[ -s "models/checkpoints/$IMAGE_MODEL" ]] || fail 'Image model is missing; repair the installation.'

# flock is authoritative: kernel releases it on a crash. Never unlink its
# inode, which could allow competing processes to lock different files.
# Start the existing backend only if its API is unavailable.
if ! .venv/bin/python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8188/system_stats",timeout=3)' >/dev/null 2>&1; then
 precision_flag=--auto
 [[ "$IMAGE_DTYPE" != float16 ]] || precision_flag=--fp16
 [[ "$IMAGE_DTYPE" != float32 ]] || precision_flag=--fp32
 STACK_CHILD=1 COMFY_BACKEND_ONLY=1 IMAGE_PORT=8188 bash ./start-comfyswarm.sh --local --non-interactive --gpu "$gpu" "$precision_flag" --background
fi
.venv/bin/python - <<'WAITBACKEND'
import time,urllib.request
for attempt in range(120):
 try:
  urllib.request.urlopen('http://127.0.0.1:8188/system_stats',timeout=2); break
 except Exception: time.sleep(1)
else: raise SystemExit('ComfyUI did not become ready; inspect image-server.log.')
WAITBACKEND
lock="$PWD/.swarm-session.lock"
session="$PWD/.swarm-session.info"
exec 9>"$lock"
if ! flock -n 9; then
    printf '\nComfyUI already has an active launcher session.\n'
    [[ ! -f "$session" ]] || cat "$session"
    exit 1
fi
owns_lock=true
if [[ -f "$session" ]]; then
    printf '\nRecovered stale session metadata; the kernel lock is free.\n'
    cat "$session"
fi
# Detect a listener even if it was started without this launcher.
IMAGE_BIND="$bind" .venv/bin/python - <<'PORTCHECK'
import os,socket,time
# Match the HTTP server’s reuse-address behavior: TCP TIME_WAIT after a
# shutdown must not be mistaken for a live listener.
for attempt in range(51):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        try:
            sock.bind((os.environ['IMAGE_BIND'],int(os.environ['IMAGE_PORT'])))
            break
        except OSError as e:
            if attempt==50: raise SystemExit(f'Port is unavailable: {e}. Inspect its owner or choose --port.')
    if attempt==0: print('Waiting briefly for the previous listener to release the port...',flush=True)
    time.sleep(.2)

PORTCHECK
printf 'Launcher PID: %s\nStarted: %s\nGPU: %s\nModel: %s\nPort: %s\n' "$$" "$(date -Is)" "$gpu" "$IMAGE_MODEL" "$IMAGE_PORT" > "$session"
chmod 600 "$session"
export CUDA_VISIBLE_DEVICES="$gpu"
export IMAGE_BIND="$bind"
if [[ "$bind" != 127.0.0.1 ]]; then
    printf '\nBrowser: http://<host-LAN-IP>:%s\n\n' "$IMAGE_PORT"
else
    printf '\nBrowser: http://127.0.0.1:%s (local or SSH tunnel)\n\n' "$IMAGE_PORT"
fi
log="$PWD/swarm-server.log"
if [[ "$foreground" == false ]]; then
    printf '\nStarting SwarmUI in background. Log: %s\n' "$log"
    # Protect potentially sensitive user prompts/lyrics written by ComfyUI logs.
    (umask 077; touch "$log")
    chmod 600 "$log"
fi
# Child inherits the kernel lock: even if launcher dies, a surviving server
# prevents another launcher from starting. Supervisor cleans metadata on exit.
# A detached session survives SSH disconnection; redirect output away from terminal.
# Foreground mode uses the same process group, supervised by this shell.
if [[ "$foreground" == true ]]; then exec 7>&1; else exec 7>>"$log"; fi
setsid .venv/bin/python - >&7 2>&1 <<'PYIMAGE' &
import os
from pathlib import Path
root=Path.cwd()/'SwarmUI'
os.chdir(root)
os.environ['DOTNET_ROOT']=str(root/'.dotnet')
os.execv(str(root/'.dotnet/dotnet'), ['dotnet',str(root/'src/bin/live_release/SwarmUI.dll'),
 '--host',os.environ['IMAGE_BIND'],'--port',os.environ['IMAGE_PORT'],'--launch_mode','none'])

PYIMAGE
child=$!
printf 'Server process: %s\n' "$child" >> "$session"
# Record Linux process start time to prevent signalling a recycled PID.
.venv/bin/python - "$child" <<'RECORD'
import json,os,sys,time
from pathlib import Path
pid=int(sys.argv[1])
for _ in range(100):
    try:
        fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
        if os.getpgid(pid)==pid: break
    except OSError: pass
    time.sleep(.02)
else: raise SystemExit('Server exited before its process identity could be recorded. Check swarm-server.log.')
info={'pid':pid,'start_token':fields[19], 'directory':str(Path.cwd()),
      'port':os.environ['IMAGE_PORT'],'model':os.environ['IMAGE_MODEL']}
p=Path('.swarm-server.json');tmp=p.with_suffix('.tmp')
tmp.write_text(json.dumps(info));tmp.chmod(0o600);tmp.replace(p)
RECORD
if [[ "$foreground" == false ]]; then
    # Child now owns the inherited lock. Parent exits without stopping it.
    child=''
    owns_lock=false
    exec 9>&-
    exec 7>&-
    printf '\nSwarmUI launched. Initialization continues in the background.\n'
    if [[ ${STACK_CHILD:-0} != 1 ]]; then
     printf 'Status: start-comfyswarm --status\nLogs: start-comfyswarm --logs --service swarmui\nStop: start-comfyswarm --stop\n'
    fi
    exit 0
fi
wait "$child"
child=''

SWARMLAUNCHER
chmod +x start-comfyswarm.sh
rm -f -- start-image.sh start-swarm.sh
sed -i "s/IMAGE_GPU_INDEX:-0/IMAGE_GPU_INDEX:-$gpu/" start-comfyswarm.sh
printf '\nInstallation complete. Start with: %s/start-comfyswarm.sh\n' "$dest"
printf 'Starter workflow: %s/workflows/comfyui-starter.json\n' "$dest"
printf 'For the simple interface, use start-comfyswarm.sh and open port 7801. Choose the Animagine model, enter a prompt, and click Generate.\n'
if [[ "$add_profile" == true ]]; then
 case "$(basename "${SHELL:-/bin/bash}")" in
  bash) profile="$HOME/.bashrc" ;;
  zsh) profile="${ZDOTDIR:-$HOME}/.zshrc" ;;
  *) profile=''; printf 'Automatic profile setup supports Bash/Zsh only.\n' ;;
 esac
 if [[ -n "$profile" ]]; then
  .venv/bin/python - "$profile" "$dest" <<'PROFILE'
import sys,shlex,shutil,time
from pathlib import Path
p=Path(sys.argv[1]);p.parent.mkdir(parents=True,exist_ok=True);s=p.read_text() if p.exists() else ''
begin='# >>> ComfyUI helper >>>';end='# <<< ComfyUI helper <<<'
if s.count(begin)!=s.count(end) or s.count(begin)>1:raise SystemExit('Ambiguous profile markers; no changes made.')
if begin in s:s=s[:s.index(begin)]+s[s.index(end)+len(end):]
if p.exists():shutil.copy2(p,p.with_name(p.name+'.image-backup.'+str(time.time_ns())))
d=sys.argv[2]
block=begin+'\nexport PATH='+shlex.quote(d)+':"$PATH"\nalias start-comfyswarm='+shlex.quote(shlex.quote(d+'/start-comfyswarm.sh'))+'\n'+end+'\n'
p.write_text(s.rstrip()+'\n\n'+block)
print('Profile updated:',p,'; open a new shell or source it.')
PROFILE
 fi
fi
if [[ "$resume" == true ]]; then flock -u 8; exec 8>&-; fi
if [[ -n ${swarm:-} ]]; then flock -u 9 2>/dev/null || true; exec 9>&-; fi
if [[ "$start_after" == true ]]; then
 if bash "$dest/start-comfyswarm.sh" "$access_flag" --non-interactive; then
  if ask 'Generate and verify the included first test image now?'; then
   if ! .venv/bin/python - <<'SWARMTEST'
import io,json,time,urllib.request,urllib.parse
from PIL import Image,ImageStat
base='http://127.0.0.1:7801'
def call(route,data,timeout=15):
 req=urllib.request.Request(base+'/API/'+route,json.dumps(data).encode(),{'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=timeout) as r: result=json.load(r)
 if 'error' in result: raise RuntimeError(result['error'])
 return result
for attempt in range(120):
 try: session=call('GetNewSession',{})['session_id'];break
 except Exception: time.sleep(1)
else: raise SystemExit('SwarmUI did not initialize; inspect swarm-server.log.')
models=call('ListModels',{'session_id':session,'path':'','depth':4})['files']
model=next((m['name'] for m in models if 'animagine-xl-4.0-opt' in m['name']),None)
if not model: raise SystemExit('SwarmUI cannot see the Animagine model. Check Server > Backends and model paths.')
print('SwarmUI sees the shared model. Generating its first test image...',flush=True)
result=call('GenerateText2Image',{'session_id':session,'images':1,'model':model,
 'prompt':'masterpiece, best quality, anime illustration, a traveler in a garden, clean line art, soft daylight',
 'negativeprompt':'low quality, blurry, bad anatomy','width':1024,'height':1024,
 'steps':28,'cfgscale':5,'seed':12345},timeout=600)
url=base+'/'+urllib.parse.quote(result['images'][0].lstrip('/'),safe='/')
with urllib.request.urlopen(url,timeout=30) as r: image=Image.open(io.BytesIO(r.read()));image.load()
assert image.size==(1024,1024) and max(ImageStat.Stat(image.convert('RGB')).stddev)>1,'Invalid/blank image'
print('SUCCESS: SwarmUI generated a nonblank 1024 x 1024 image. Find it in browser history.')
SWARMTEST
then
    printf '\nFirst-image test failed; installation is retained. Inspect start-comfyswarm --logs --service comfyui.\n' >&2
    exit 1
   fi
  fi
 else
  printf '\nComfyUI startup failed. Installation is retained; inspect image-server.log.\n' >&2
  exit 1
 fi
fi
printf '\nFor remote access from Linux, macOS, or Windows with an SSH client: ssh -N -L 7801:127.0.0.1:7801 user@host\n'
printf 'Run the SSH command on your client computer, replacing user@host with your server login.\nKeep the SSH session open, then open http://localhost:7801 in that computer’s browser.\n'
