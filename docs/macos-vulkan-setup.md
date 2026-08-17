# Running Glim on macOS

Glim bakes with `VK_KHR_ray_query`. Every Mac has a capable ray tracing unit behind
Metal, but **stock MoltenVK does not expose it as a Vulkan extension**, so Glim
fails the bake with `Expected RayQuery variant` on an otherwise healthy install.

Verified on macOS 26.5 / Apple Silicon (M5 Max) with Unity 2022.3.22f1,
MoltenVK 1.4.3, OIDN 2.5.0.

---

## Quick start

```bash
brew install open-image-denoise vulkan-loader vulkan-headers
./tools/setup-macos-vulkan.sh
./tools/setup-macos-vulkan.sh --set-global
```

Restart Unity **and Unity Hub**, then bake.

If a prebuilt driver has been published, set these first and installation takes
seconds instead of a 15–40 minute build:

```bash
export GLIM_MOLTENVK_URL=...
export GLIM_MOLTENVK_SHA256=...
```

| Flag | Effect |
|---|---|
| `--check` | Report state and whether ray query is advertised. Changes nothing. |
| `--env` | Print the `export` lines, for a launcher script. |
| `--set-global` / `--unset-global` | Set the variables machine-wide via `launchctl`. |
| `--loader-free` | Install only the driver, no loader stack. Needs Patch A — see below. |
| `--rebuild` | Force a fresh MoltenVK build. |
| `--uninstall` | Remove exactly what was installed. |

Everything lives under `$HOME`. Nothing goes system-wide.

---

## What gets installed, and why

| Piece | Why |
|---|---|
| `~/.local/lib/glim-vulkan/libMoltenVK.dylib` | The ray-query MoltenVK build. Private prefix so it doesn't become the machine's Vulkan implementation. |
| `~/.local/share/vulkan/icd.d/MoltenVK_icd.json` | Tells the Vulkan loader this driver exists. Needs `is_portability_driver: true`, or loaders hide it. |
| `~/lib/libvulkan.dylib` (symlink) | Ash asks `dlopen` for a **bare** `libvulkan.dylib`, which macOS resolves only against `DYLD_FALLBACK_LIBRARY_PATH` — and Unity replaces that with its own `Contents/Frameworks`. `$HOME/lib` is a default fallback entry, so it's found both from a terminal and inside the editor. |
| `GLIM_VULKAN_LOADER` | Names the loader explicitly, ahead of any search. |
| `MVK_CONFIG_ENABLE_EXPERIMENTAL_RAY_TRACING=1` | MoltenVK keeps ray query behind this flag. |
| `VK_DRIVER_FILES` / `VK_ICD_FILENAMES` | Pins the loader to this driver. See below. |

### Pinning the driver is not optional

A Homebrew `molten-vk` install puts a **stock** MoltenVK — no ray query — at
`/opt/homebrew/etc/vulkan/icd.d/`, on the same loader search path. The loader then
enumerates both:

```
GPU0: driverInfo = 1.4.3   <- ray query build
GPU1: driverInfo = 1.4.2   <- stock Homebrew molten-vk, no ray query
```

Glim sorts physical devices checking `VK_KHR_ray_query` **only for `DISCRETE_GPU`**.
Apple Silicon reports `INTEGRATED_GPU`, so the two drivers tie and Glim takes
whichever the loader returned first — a coin flip between a working bake and
`Expected RayQuery variant`. With the pin set, only the 1.4.3 driver is enumerated.

---

## The driver

Ray query is [MoltenVK PR #2771](https://github.com/KhronosGroup/MoltenVK/pull/2771),
not yet merged. Homebrew's `molten-vk` will not work.

**Check whether the PR has merged first.** If it has, this collapses to
`brew install molten-vk`.

### Option A — prebuilt (seconds)

The published binary and its checksum are the script's defaults, so this needs no
configuration. Override with `GLIM_MOLTENVK_URL` / `GLIM_MOLTENVK_SHA256` to point
elsewhere. The checksum is mandatory — the script refuses to install a binary it
cannot verify. If the source is a private repo, the download falls back to
`GITHUB_TOKEN` and then `gh api`, since GitHub answers unauthenticated requests
with 404 rather than 401.

### Option B — build from source (15–40 minutes)

Needs **full Xcode**, not just the Command Line Tools, because the build drives
`xcodebuild` against MoltenVK's own project:

```bash
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
```

By hand:

```bash
git clone --depth 1 --branch macgaming/ray-query-pr \
  https://github.com/dttdrv/MoltenVK.git ~/.cache/glim/MoltenVK
cd ~/.cache/glim/MoltenVK
./fetchDependencies --macos     # SPIRV-Cross, SPIRV-Tools, cereal
make macos
cp Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib \
   ~/.local/lib/glim-vulkan/
```

The result is a universal binary (x86_64 + arm64), so one file serves every Mac.
MoltenVK is Apache-2.0, so publishing it for a team is fine with attribution and a
statement of modification — it is built from an unmerged PR branch, not upstream.

---

## Launching Unity

The variables must be set in the process that launches Unity. `.zshrc` won't do it
— the editor is started by Unity Hub, which doesn't read your shell profile.

**Machine-wide:** `./tools/setup-macos-vulkan.sh --set-global` uses `launchctl
setenv`, which GUI-launched apps inherit. Persists until `--unset-global`.

**Per-project:** put the output of `--env` in a launcher script that `exec`s Unity.

---

## Source patches

Glim's macOS library loading was fixed upstream in
[`e922d3d`](https://github.com/z3y/glim/commit/e922d3dd7276c5f1ec4f24b56c192ede9ee2e596)
("fix paths for macos libs"), covering both the Vulkan loader search — including
the `GLIM_VULKAN_LOADER` override this setup relies on — and OIDN's versioned
library name plus Homebrew paths. **Nothing to apply.**

Earlier, `b8c111d` added `VK_KHR_portability_enumeration` / `portability_subset`.

Three items remain outstanding.

### Patch A — conditional `portability_enumeration`

Required for `--loader-free`, and correct regardless: an extension should never be
enabled without checking it is advertised. `src/vulkan_context.rs` currently does:

```rust
#[cfg(target_os = "macos")]
{
    extensions.push(vk::KHR_PORTABILITY_ENUMERATION_NAME.as_ptr());
}
```

`VK_KHR_portability_enumeration` is synthesized by the Vulkan **loader**, not by
MoltenVK. Through the loader this is fine. Loading MoltenVK directly it fails:

```
[mvk-error] VK_ERROR_EXTENSION_NOT_PRESENT:
            Vulkan extension VK_KHR_portability_enumeration is not supported.
```

Measured: loaded directly, MoltenVK 1.4.3 advertises 18 instance extensions and
this is not among them. (`portability_subset` is a *device* extension and is
advertised normally.) Guard the push with an availability check, mirroring how the
same file already handles `portability_subset`. With that guard, direct loading
works end to end — instance created, `ray_query=true`, `accel_structure=true`.

### Patch B — `build.sh` uses Linux library naming

`build.sh` copies `target/release/libglim.so` to `unity/Editor/glim.so`, but macOS
cargo emits `libglim.dylib` and Unity's `DllImport("glim")` wants `glim.dylib`:

```bash
case "$(uname -s)" in
  Darwin) cp target/release/libglim.dylib unity/Editor/glim.dylib ;;
  *)      cp target/release/libglim.so    unity/Editor/glim.so    ;;
esac
```

### Patch C — Light Volumes 3 compatibility

Glim's `#if VRC_LIGHT_VOLUMES` block targets the LV2 API and does not compile
against `red.sim.lightvolumes` 3.x. In LV3:

- `LightVolumeSetup` is `[Obsolete]` — *"Legacy authoring data. Use
  LightVolumeManager; this component is consumed by the 3.x migration."*
- `GenerateAtlas` moved to an extension method on `LightVolumeManager`, in
  `LightVolumeManagerTools` (assembly `red.sim.LightVolumesEditor`).
- `LightVolumeManager` lives in `red.sim.LightVolumesUdon` and derives from
  `UdonSharpBehaviour`.

LV3 sets the same `VRC_LIGHT_VOLUMES` define as LV2, so there is no built-in way to
tell them apart. Distinguish by package version in the asmdef:

```json
{ "name": "red.sim.lightvolumes",
  "expression": "[3.0.0-dev.0,4.0.0)",
  "define": "VRC_LIGHT_VOLUMES_3" }
```

The lower bound must include prereleases — `3.0.0-dev.14` sorts *before* `3.0.0`,
so a plain `3.0.0` bound would not match a dev build.

Then add references to `red.sim.LightVolumesUdon`, `red.sim.LightVolumesEditor`
and `UdonSharp.Runtime`, and branch the call:

```csharp
#if VRC_LIGHT_VOLUMES_3
    var lvManager = ctx.scene.GetRootGameObjects()
        .SelectMany(x => x.GetComponentsInChildren<VRCLightVolumes.LightVolumeManager>(false))
        .FirstOrDefault();
    if (lvManager)
        VRCLightVolumes.LightVolumeManagerTools.GenerateAtlas(lvManager);
#else
    // existing LightVolumeSetup path
#endif
```

Call it as a static, not with extension syntax: `GenerateAtlas` is an extension in
namespace `VRCLightVolumes`, and `Bake.cs` fully-qualifies every LV type with no
`using VRCLightVolumes;` in scope, so extension lookup never finds it.

---

## Requirements

| | |
|---|---|
| **Required** | macOS, `open-image-denoise` **2.x** |
| **Required (default mode)** | `vulkan-loader`, `vulkan-headers` — not needed with `--loader-free` |
| **Required to build from source** | full Xcode, `cmake`, `git` |
| **Optional** | `vulkan-tools` (verification only) |

OIDN must be 2.x: in 1.x `oidnSetFilterBool` is spelled `oidnSetFilter1b`, so a 1.x
install loads fine and then fails at symbol binding. The script checks up front.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Expected RayQuery variant` | Flag not set in the launching process, or the wrong MoltenVK. Without the flag the device reports 132 extensions and no ray query; with it, 137 and `ray_query=true`. |
| Set the variable but nothing changed | Unity inherited the old environment. Quit Unity **and** Unity Hub, then relaunch. |
| Works intermittently | Two MoltenVK drivers on the loader path — set `VK_DRIVER_FILES`. |
| Vulkan not found in Unity, fine in terminal | `GLIM_VULKAN_LOADER` unset, or a Glim build predating `e922d3d`. |
| Missing `oidnSetFilterBool` | Unity's bundled OIDN 1.3 got loaded — needs `e922d3d`. |
| `ERROR_EXTENSION_NOT_PRESENT` for `portability_enumeration` | `--loader-free` without Patch A. |
| Native plugin missing in Unity | Patch B — wrong library extension. |
| `GenerateAtlas` / `UdonSharpBehaviour` compile errors | Patch C — LV3 API change. |

`--check` reports every component, whether MoltenVK exports the entry points,
whether ray query is advertised, and the current `launchctl` values. Running Unity
from a terminal shows which loader and which OIDN were resolved — upstream prints
`Vulkan loader: <path>` on startup.

---

## Uninstalling

```bash
./tools/setup-macos-vulkan.sh --uninstall
```

Removes the driver, ICD manifest, loader symlink and `launchctl` variables — the
symlink only if it is the one the script created, and the variables only if
`GLIM_VULKAN_LOADER` names this install. The MoltenVK checkout and Homebrew
packages are left alone.
