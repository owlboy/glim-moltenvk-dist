# glim-moltenvk-dist

A MoltenVK build for macOS with `VK_KHR_ray_query`, for the
[Glim](https://github.com/z3y/glim) lightmapper, plus the script that installs it.

Glim bakes with `VK_KHR_ray_query`. Stock MoltenVK does not implement it, including
Homebrew's `molten-vk`, so the bake fails with `Expected RayQuery variant`. This is a
build that does.

This is not a general-purpose MoltenVK distribution. It comes from an unmerged pull
request and carries a local patch. See [Provenance](#provenance).

## Install

Install the prerequisites first. The script does not manage them.

```bash
brew install vulkan-loader vulkan-tools
```

Then:

```bash
curl -fsSL https://raw.githubusercontent.com/owlboy/glim-moltenvk-dist/main/tools/setup-macos-vulkan.sh | bash
```

Restart Unity and Unity Hub, then bake.

If you have the repo checked out, `./tools/setup-macos-vulkan.sh` does the same thing.

## What the script does

| Step | |
|---|---|
| 1. Get the driver | Downloads and verifies the checksum, or builds from source if no URL is set. |
| 2. Install | `~/.local/lib/glim-vulkan/libMoltenVK.dylib` |
| 3. Register | Writes an ICD manifest to `~/.local/share/vulkan/icd.d/`, and symlinks `~/lib/libvulkan.dylib` so Glim can find the loader from inside Unity. |
| 4. Verify | Confirms ray query is advertised. |
| 5. Set the environment | Four `launchctl` variables so Unity Hub inherits them: the loader path, the ray-tracing flag, and two driver-pin variables that exclude any stock MoltenVK installed elsewhere on the machine. |

Pass `--no-global` to skip step 5 and print the `export` lines instead.

Everything is written under `$HOME`; nothing goes system-wide.

## Modes

| | |
|---|---|
| (no flags) | Install the driver and set the environment |
| `--check` | Report state and whether ray query works. Changes nothing. |
| `--env` | Print the `export` lines, for a launcher script instead of `--set-global`. |
| `--set-global` / `--unset-global` | Set or clear the variables on their own. |
| `--no-global` | Install without setting the environment. |
| `--loader-free` | Driver only, no loader stack. Requires a Glim patch (see the docs). |
| `--rebuild` | Force a fresh source build. |
| `--uninstall` | Remove exactly what was installed. |

Setup notes, troubleshooting and the outstanding Glim patches are in
[`docs/macos-vulkan-setup.md`](docs/macos-vulkan-setup.md).

## Contents

| | |
|---|---|
| `libMoltenVK.dylib` | The driver. Universal binary, `x86_64` + `arm64`. |
| `SHA256SUMS` | Checksum. |
| `tools/` | The install script. |
| `docs/` | Setup notes and troubleshooting. |
| `patches/` | The local MoltenVK patch applied to this build. |
| `LICENSE`, `NOTICE`, `third-party/` | Apache-2.0, attribution, statement of modification, component licenses. |

## Artifact

```
File     libMoltenVK.dylib
Size     11620608 bytes
SHA-256  ec080b0feb76ea52a2bce0af0c0e9ccead2357e63af22027a12375e1cc6ecc04
Arch     x86_64, arm64 (universal)
Reports  MoltenVK 1.4.3
```

## Provenance

Built from a fork of MoltenVK carrying
[pull request #2771](https://github.com/KhronosGroup/MoltenVK/pull/2771), which adds
`VK_KHR_ray_query`. That pull request was not merged upstream when this binary was
produced, and no release of MoltenVK contains it.

```
Upstream    https://github.com/KhronosGroup/MoltenVK
Fork        https://github.com/dttdrv/MoltenVK
Branch      macgaming/ray-query-pr
Commit      95bd449  ("Update SPIRV-Cross ray tracing revision")
Local patch patches/0001-fix-descriptor-pool-destructor-dangling-layout.patch
Built       2026-08-17
Host        macOS 26.5, Apple Silicon
```

### Local patch

`~MVKDescriptorPool` walked its descriptor sets to release acceleration structure
references, reaching the lock through `set->layout->getDevice()`.
`MVKDescriptorSet::layout` is a raw pointer, and the Vulkan spec permits destroying a
`VkDescriptorSetLayout` while sets allocated from it are still alive. Glim destroys its
layouts before the pool, which left that pointer dangling and aborted the process at the
end of a completed bake:

```
libc++abi: terminating due to uncaught exception of type
std::__1::system_error: mutex lock failed: Invalid argument
```

The patch drops that walk from the destructor only. `reset()` and `freeDescriptorSets()`
keep it, since there the layouts are still live.

## Licensing

MoltenVK is licensed under the Apache License 2.0. See `NOTICE` for attribution, the
statement of modification under Apache-2.0 section 4(b), and the third-party component
list.

The binary is provided as is, without warranty of any kind. It is an unmerged,
experimental build and is not a conformant Vulkan implementation.
