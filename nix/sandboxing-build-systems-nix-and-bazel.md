# Build Sandboxing in Nix and Bazel: A Comparative Study

Both [Nix](https://github.com/NixOS/nix) and [Bazel](https://github.com/bazelbuild/bazel)
are build systems that pursue **reproducible, hermetic builds**. Both use Linux
kernel namespaces to isolate build processes. But they arrive at sandboxing from
very different philosophical starting points, and — as of today — their
sandboxes don't compose well when one runs inside the other.

This document explores how each system implements sandboxing at the Linux kernel
level, compares their design philosophies, and considers how changes on either
side could make them work together. The goal is not to argue that one approach
is better, but to understand the trade-offs deeply enough to find a path toward
interoperability.

Both projects represent years of careful engineering. We hope this comparison is
useful to contributors and users of both ecosystems.

---

## Table of Contents

- [1. Background: What Problem Does Build Sandboxing Solve?](#1-background-what-problem-does-build-sandboxing-solve)
- [2. The Linux Kernel Primitives](#2-the-linux-kernel-primitives)
- [3. Nix's Sandbox: The Allowlist Model](#3-nixs-sandbox-the-allowlist-model)
  - [3.1 Namespace Creation](#31-namespace-creation)
  - [3.2 Filesystem Construction](#32-filesystem-construction)
  - [3.3 The Nix Store: Shared Subtree for Dynamic Injection](#33-the-nix-store-shared-subtree-for-dynamic-injection)
  - [3.4 Pivot Root](#34-pivot-root)
  - [3.5 Fixed-Output Derivations](#35-fixed-output-derivations)
- [4. Bazel's Sandbox: The Denylist Model](#4-bazels-sandbox-the-denylist-model)
  - [4.1 Namespace Creation](#41-namespace-creation)
  - [4.2 Non-Hermetic Mode (Default)](#42-non-hermetic-mode-default)
  - [4.3 Hermetic Mode](#43-hermetic-mode)
  - [4.4 Repository Rules: No Sandbox at All](#44-repository-rules-no-sandbox-at-all)
- [5. Side-by-Side Comparison](#5-side-by-side-comparison)
  - [5.1 Kernel Primitive Usage](#51-kernel-primitive-usage)
  - [5.2 Mount Namespace Setup Sequences](#52-mount-namespace-setup-sequences)
  - [5.3 What's Visible Inside the Sandbox](#53-whats-visible-inside-the-sandbox)
  - [5.4 Design Philosophy Comparison](#54-design-philosophy-comparison)
- [6. The Composition Problem](#6-the-composition-problem)
  - [6.1 What Happens When Bazel Runs Inside Nix](#61-what-happens-when-bazel-runs-inside-nix)
  - [6.2 The ELF Interpreter Problem](#62-the-elf-interpreter-problem)
  - [6.3 Repository Rules: The Hardest Case](#63-repository-rules-the-hardest-case)
- [7. Potential Changes to Improve Interoperability](#7-potential-changes-to-improve-interoperability)
  - [7.1 Changes on the Bazel Side](#71-changes-on-the-bazel-side)
  - [7.2 Changes on the Nix Side](#72-changes-on-the-nix-side)
  - [7.3 Changes in the Bazel Rule Ecosystem](#73-changes-in-the-bazel-rule-ecosystem)
- [8. Summary](#8-summary)

---

## 1. Background: What Problem Does Build Sandboxing Solve?

Build sandboxing ensures that a build process can only access its **declared
inputs** and can only produce its **declared outputs**. Without sandboxing, a
build might accidentally depend on a file that happens to exist on the developer's
machine but not in CI, leading to "works on my machine" failures. Sandboxing
catches these undeclared dependencies by making undeclared files invisible.

Both Nix and Bazel implement this using Linux kernel namespaces — the same
primitives used by Docker and other container runtimes. The key namespace for
build sandboxing is the **mount namespace**, which gives each process its own
view of the filesystem.

---

## 2. The Linux Kernel Primitives

Both systems use the same small set of Linux system calls:

| Primitive | Purpose |
|-----------|---------|
| `clone(CLONE_NEWNS)` | Create a new mount namespace |
| `clone(CLONE_NEWPID)` | Create a new PID namespace (process isolation) |
| `clone(CLONE_NEWNET)` | Create a new network namespace (network isolation) |
| `clone(CLONE_NEWUSER)` | Create a new user namespace (UID/GID mapping) |
| `mount(MS_BIND)` | Bind-mount a directory from one path to another |
| `mount(MS_PRIVATE)` | Prevent mount propagation between namespaces |
| `mount(MS_SHARED)` | Allow mount propagation between namespaces |
| `mount(MS_RDONLY \| MS_REMOUNT)` | Make a mount read-only |
| `pivot_root()` | Atomically swap the root filesystem |
| `chroot()` | Change the apparent root directory |

The critical distinction is between `MS_PRIVATE` and `MS_SHARED`:

- **`MS_PRIVATE`**: Mounts made in this namespace are invisible to the parent,
  and vice versa. This is full isolation.
- **`MS_SHARED`**: Mounts propagate bidirectionally between parent and child
  namespaces. This allows controlled communication.

---

## 3. Nix's Sandbox: The Allowlist Model

Nix's sandbox philosophy: **start with nothing, add only what's declared.**

The build process sees an empty filesystem. Only the derivation's declared
`inputPaths` (and their transitive closures in the Nix store), plus a small
set of system paths, are bind-mounted into the sandbox.

The implementation lives in a single file:
[`src/libstore/unix/build/linux-derivation-builder.cc`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc)

### 3.1 Namespace Creation

Nix creates its sandbox using `clone()` with multiple namespace flags.
A helper process forks the actual builder child:

[`linux-derivation-builder.cc:357-361`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L357-L361)
```cpp
ProcessOptions options;
options.cloneFlags = CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWIPC
                   | CLONE_NEWUTS | CLONE_PARENT | SIGCHLD;
if (derivationType.isSandboxed())
    options.cloneFlags |= CLONE_NEWNET;
if (usingUserNamespace)
    options.cloneFlags |= CLONE_NEWUSER;
```

Notably, **network isolation is conditional**: fixed-output derivations (FODs)
that need to download files are *not* given `CLONE_NEWNET`. This is how `fetchurl`
and similar functions access the network. More on this in
[Section 3.5](#35-fixed-output-derivations).

### 3.2 Filesystem Construction

Inside the child process, `enterChroot()` builds the sandbox filesystem from
scratch.

**Step 1: Isolate from parent mount propagation**

[`linux-derivation-builder.cc:498`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L498)
```cpp
if (mount(0, "/", 0, MS_PRIVATE | MS_REC, 0) == -1)
    throw SysError("unable to make '/' private");
```

This makes every mount in the namespace private, preventing propagation from
the parent namespace.

**Step 2: Prepare the chroot directory structure**

Before entering the child, the parent process creates a directory hierarchy at
`chrootRootDir` (typically inside the Nix store) with `/tmp`, `/etc/passwd`,
`/etc/group`, and `/etc/hosts`:

[`chroot-derivation-builder.cc:55-151`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/chroot-derivation-builder.cc#L55-L151)

**Step 3: Populate the chroot with declared inputs**

The set of paths to mount is determined by `getPathsInSandbox()`:

[`derivation-builder.cc:887-959`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/derivation-builder.cc#L887-L959)

This merges:
- **`sandbox-paths`** from `nix.conf` — system-wide paths like `/bin/sh`
  ([`globals.cc:107`](https://github.com/NixOS/nix/blob/master/src/libstore/globals.cc#L107))
- **`extra-sandbox-paths`** from a pre-build hook
- **`impureHostDeps`** from the derivation (if allowed)
- **`inputPaths`** — the transitive closure of all declared build inputs from
  the Nix store
  ([`chroot-derivation-builder.cc:130-135`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/chroot-derivation-builder.cc#L130-L135))

Each path is bind-mounted into the chroot using a `doBind()` helper:

[`linux-derivation-builder.cc:128-158`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L128-L158)
```cpp
static void doBind(const std::filesystem::path & source,
                   const std::filesystem::path & target,
                   bool optional = false) {
    // ...
    if (S_ISDIR(st.st_mode)) {
        createDirs(target);
        bindMount();  // mount(source, target, MS_BIND | MS_REC)
    } else if (S_ISLNK(st.st_mode)) {
        // Symlinks can't be bind-mounted — copy instead
        copyFile(source, target, false);
    } else {
        createDirs(target.parent_path());
        writeFile(target, "");
        bindMount();
    }
}
```

The actual bind-mount loop:

[`linux-derivation-builder.cc:584-602`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L584-L602)
```cpp
for (auto & i : pathsInChroot) {
    if (i.second.source == "/proc")
        continue;
    // ...
    doBind(i.second.source,
           chrootRootDir / i.first.relative_path(),
           i.second.optional);
}
```

**Step 4: Mount special filesystems**

[`linux-derivation-builder.cc:604-646`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L604-L646)
```cpp
// /proc
mount("none", (chrootRootDir / "proc").c_str(), "proc", 0, 0);
// /sys (only with UID ranges)
mount("none", (chrootRootDir / "sys").c_str(), "sysfs", 0, 0);
// /dev/shm (tmpfs for shared memory cleanup)
mount("none", (chrootRootDir / "dev" / "shm").c_str(), "tmpfs", 0, ...);
// /dev/pts (pseudo-terminals)
mount("none", (chrootRootDir / "dev" / "pts").c_str(), "devpts", 0, ...);
```

### 3.3 The Nix Store: Shared Subtree for Dynamic Injection

This is one of Nix's most elegant sandbox mechanisms. Before calling
`pivot_root()`, Nix marks the store directory as `MS_SHARED`:

[`linux-derivation-builder.cc:506-520`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L506-L520)
```cpp
/* Bind-mount the sandbox's Nix store onto itself so that
   we can mark it as a "shared" subtree, allowing bind
   mounts made in *this* mount namespace to be propagated
   into the child namespace created by the
   unshare(CLONE_NEWNS) call below. */
std::filesystem::path chrootStoreDir =
    chrootRootDir / std::filesystem::path(store.storeDir).relative_path();

mount(chrootStoreDir.c_str(), chrootStoreDir.c_str(), 0, MS_BIND, 0);
mount(0, chrootStoreDir.c_str(), 0, MS_SHARED, 0);
```

Then, a second `unshare(CLONE_NEWNS)` creates a child mount namespace:

[`linux-derivation-builder.cc:662`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L662)
```cpp
if (unshare(CLONE_NEWNS) == -1)
    throw SysError("unsharing mount namespace");
```

**Why two mount namespaces?** Because `pivot_root()` changes the root of the
mount namespace. If Nix later needs to add a new store path (e.g., a
dynamically discovered build dependency), it enters the *first* mount namespace
(saved before `pivot_root()`) and bind-mounts the new path there. Because the
store subtree is `MS_SHARED`, the new mount propagates into the second
(post-pivot_root) namespace where the build is actually running:

[`linux-derivation-builder.cc:728-751`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L728-L751)
```cpp
void addDependencyImpl(const StorePath & path) override {
    auto [source, target] = ChrootDerivationBuilder::addDependencyPrep(path);

    Pid child(startProcess([&]() {
        if (usingUserNamespace
            && (setns(sandboxUserNamespace.get(), CLONE_NEWUSER) == -1))
            throw SysError("entering sandbox user namespace");

        if (setns(sandboxMountNamespace.get(), CLONE_NEWNS) == -1)
            throw SysError("entering sandbox mount namespace");

        doBind(source, target);
        _exit(0);
    }));
    // ...
}
```

This is a capability Bazel's sandbox does not have.

### 3.4 Pivot Root

After all mounts are in place, Nix performs the standard `pivot_root()` +
`chroot()` + detach sequence:

[`linux-derivation-builder.cc:672-688`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L672-L688)
```cpp
chdir(chrootRootDir.c_str());
mkdir("real-root", 0500);
pivot_root(".", "real-root");
chroot(".");
umount2("real-root", MNT_DETACH);
rmdir("real-root");
```

After this, the old root filesystem is completely detached. The build process
can only see what was explicitly bind-mounted into the chroot.

### 3.5 Fixed-Output Derivations

Fixed-output derivations (FODs) are derivations whose output is identified by
its content hash rather than by the build process that produced it. This means
the build is allowed to be impure — specifically, it may access the network.

The key difference for FODs:

1. **No `CLONE_NEWNET`**: The network namespace isolation is skipped
   ([`linux-derivation-builder.cc:358-359`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L358-L359))

2. **DNS and TLS access**: `/etc/resolv.conf`, `/etc/services`, `/etc/hosts`,
   and CA certificates are bind-mounted into the sandbox
   ([`linux-derivation-builder.cc:553-571`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L553-L571))

3. **Same filesystem isolation**: The mount namespace is still restrictive —
   only declared inputs plus the networking files are visible.

This design is directly relevant to building Bazel inside Nix, because Bazel's
`bazel fetch` (which downloads dependencies) must run inside a FOD to get
network access.

---

## 4. Bazel's Sandbox: The Denylist Model

Bazel's sandbox philosophy for build actions: **start with the existing
filesystem, restrict write access.**

The build process sees the full parent filesystem (in non-hermetic mode), but
most of it is read-only. Only the declared output directories are writable.

The implementation has two layers:
- **Java orchestration**: Constructs the command line for the sandbox binary
  ([`LinuxSandboxedSpawnRunner.java`](https://github.com/bazelbuild/bazel/blob/master/src/main/java/com/google/devtools/build/lib/sandbox/LinuxSandboxedSpawnRunner.java))
- **C sandbox binary**: Performs the actual namespace setup
  ([`linux-sandbox-pid1.cc`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc))

### 4.1 Namespace Creation

Bazel creates its sandbox using `clone()` in
[`linux-sandbox.cc:175-194`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox.cc#L175-L194):

```cpp
int clone_flags =
    CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWIPC | CLONE_NEWPID | SIGCHLD;
if (opt.create_netns != NO_NETNS) {
    clone_flags |= CLONE_NEWNET;
}
if (opt.fake_hostname) {
    clone_flags |= CLONE_NEWUTS;
}

const pid_t child_pid = clone(Pid1Main, child_stack.data() + kStackSize,
                              clone_flags, &pid1Args);
```

The clone flags are nearly identical to Nix's. Both systems create PID, mount,
IPC, and user namespaces, with network and UTS namespaces as optional.

### 4.2 Non-Hermetic Mode (Default)

In non-hermetic mode, Bazel's sandbox setup is defined in
[`Pid1Main()`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L704-L759):

```cpp
// line 723-739
SetupMountNamespace();        // Make namespace private
SetupUserNamespace();         // Map UIDs
// ...
MountFilesystems();           // Bind-mount -M/-m, -w, -e, working dir
MakeFilesystemMostlyReadOnly(); // Remount everything read-only
MountProcAndSys();            // New /proc and /sys
```

**Step 1: Isolate mount propagation** — identical to Nix:

[`linux-sandbox-pid1.cc:202-208`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L202-L208)
```cpp
static void SetupMountNamespace() {
  if (mount(nullptr, "/", nullptr, MS_REC | MS_PRIVATE, nullptr) < 0) {
    DIE("mount");
  }
}
```

**Step 2: Apply requested mounts** — bind-mount explicitly requested paths:

[`linux-sandbox-pid1.cc:270-332`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L270-L332)
```cpp
static void MountFilesystems() {
  // Bind mount all -M/-m sources to targets
  for (size_t i = 0; i < opt.bind_mount_sources.size(); i++) {
    mount(source.c_str(), target.c_str(), nullptr,
          MS_BIND | MS_REC, nullptr);
  }

  // Mount tmpfs on -e directories
  for (const std::string &tmpfs_dir : opt.tmpfs_dirs) {
    mount("tmpfs", tmpfs_dir.c_str(), "tmpfs",
          MS_NOSUID | MS_NODEV | MS_NOATIME, nullptr);
  }

  // Bind-mount -w writable files onto themselves
  for (const std::string &writable_file : opt.writable_files) {
    mount(writable_file.c_str(), writable_file.c_str(), nullptr,
          MS_BIND | MS_REC, nullptr);
  }

  // Working directory is always writable
  mount(opt.working_dir.c_str(), opt.working_dir.c_str(), nullptr,
        MS_BIND, nullptr);
}
```

**Step 3: Make the filesystem mostly read-only** — this is the defining
characteristic of Bazel's non-hermetic mode:

[`linux-sandbox-pid1.cc:362-433`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L362-L433)
```cpp
static void MakeFilesystemMostlyReadOnly() {
  FILE *mounts = setmntent("/proc/self/mounts", "r");

  struct mntent *ent;
  while ((ent = getmntent(mounts)) != nullptr) {
    int mountFlags = MS_BIND | MS_REMOUNT;

    // Preserve existing flags (nodev, noexec, nosuid, etc.)
    if (hasmntopt(ent, "nodev") != nullptr)  mountFlags |= MS_NODEV;
    if (hasmntopt(ent, "noexec") != nullptr) mountFlags |= MS_NOEXEC;
    // ... etc

    if (!ShouldBeWritable(ent->mnt_dir)) {
      mountFlags |= MS_RDONLY;
    }

    mount(nullptr, ent->mnt_dir, nullptr, mountFlags, nullptr);
  }
}
```

The function iterates *every mount in `/proc/self/mounts`* and remounts it
read-only unless it's in the writable set. This means the entire parent
filesystem remains visible but is locked down to read-only access.

[`ShouldBeWritable()`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L336-L358)
returns true only for the working directory, explicitly marked writable paths
(`-w`), tmpfs directories (`-e`), and `/dev/pts` if PTY mode is enabled.

### 4.3 Hermetic Mode

With `--experimental_use_hermetic_linux_sandbox`, Bazel uses an approach closer
to Nix's — building the filesystem from scratch instead of inheriting the parent:

[`linux-sandbox-pid1.cc:729-735`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L729-L735)
```cpp
if (opt.hermetic) {
  MountSandboxAndGoThere();  // Bind-mount sandbox root, cd there
  CreateEmptyFile();         // Create tmp/empty_file for hard-linking
  MountDev();                // Mount /dev devices
  MountProcAndSys();         // Mount /proc and /sys
  MountAllMounts();          // Bind-mount all -M/-m as read-only
  ChangeRoot();              // pivot_root + chroot + detach old root
}
```

[`ChangeRoot()`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L682-L702)
uses the same `pivot_root()` + `chroot()` + `umount2(MNT_DETACH)` sequence as
Nix:

```cpp
static void ChangeRoot() {
  char old_root[16] = "old-root-XXXXXX";
  mkdtemp(old_root);
  syscall(SYS_pivot_root, ".", old_root);
  chroot(".");
  umount2(old_root, MNT_DETACH);
  rmdir(old_root);
}
```

In hermetic mode, Bazel's sandbox is architecturally very similar to Nix's.
The main difference is that Nix has the dynamic path injection mechanism
(`MS_SHARED` + `addDependencyImpl()`), while Bazel's hermetic sandbox is static
once created.

### 4.4 Repository Rules: No Sandbox at All

A critical distinction: **Bazel does not sandbox repository rule execution.**

Repository rules (which download and configure external dependencies) use
`repository_ctx.execute()`, which goes through Bazel's `ProcessWrapper` — a
simple timeout/signal wrapper that does NOT create mount namespaces:

[`StarlarkBaseExternalContext.java:1941-2030`](https://github.com/bazelbuild/bazel/blob/master/src/main/java/com/google/devtools/build/lib/bazel/repository/starlark/StarlarkBaseExternalContext.java#L1941-L2030)

The process wrapper merely prepends timeout flags:

```
[process-wrapper, --timeout=X, --kill_delay=Y, <actual_command>...]
```

No namespace isolation. The repository rule runs in whatever filesystem
environment exists at the time — which, when Bazel is running inside a Nix
sandbox, is Nix's sparse chroot with no FHS paths.

### 4.5 Sandbox Customization Flags

Bazel provides several flags for customizing the sandbox, defined in
[`SandboxOptions.java`](https://github.com/bazelbuild/bazel/blob/master/src/main/java/com/google/devtools/build/lib/sandbox/SandboxOptions.java):

| Flag | Purpose |
|------|---------|
| `--sandbox_add_mount_pair=src:tgt` | Add a bind mount to the sandbox |
| `--sandbox_writable_path=path` | Make a path writable in the sandbox |
| `--sandbox_tmpfs_path=path` | Mount tmpfs at a path in the sandbox |
| `--experimental_use_hermetic_linux_sandbox` | Use hermetic (Nix-like) mode |
| `--sandbox_debug` | Enable debug logging |

**These flags only affect build action sandboxes, not repository rule
execution.**

---

## 5. Side-by-Side Comparison

### 5.1 Kernel Primitive Usage

| Primitive | Nix | Bazel |
|-----------|-----|-------|
| `clone(CLONE_NEWNS)` | Yes | Yes |
| `clone(CLONE_NEWPID)` | Yes | Yes |
| `clone(CLONE_NEWNET)` | Conditional (not for FODs) | Conditional (flag) |
| `clone(CLONE_NEWUSER)` | Conditional | Yes (always) |
| `clone(CLONE_NEWIPC)` | Yes | Yes |
| `clone(CLONE_NEWUTS)` | Yes | Conditional (flag) |
| `mount(MS_PRIVATE)` | Yes (on `/`) | Yes (on `/`) |
| `mount(MS_SHARED)` | Yes (on store dir) | No |
| `pivot_root()` | Yes (always) | Only in hermetic mode |
| `chroot()` | Yes (always) | Only in hermetic mode |
| `seccomp` | Yes (filters setuid, xattr) | No |
| `unshare(CLONE_NEWNS)` | Yes (second namespace) | No |
| `setns()` | Yes (for dynamic injection) | No |

### 5.2 Mount Namespace Setup Sequences

**Nix** (from [`linux-derivation-builder.cc:459-691`](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc#L459-L691)):

```
 1. mount("/", MS_PRIVATE | MS_REC)        — cut off parent propagation
 2. mount(chrootRoot, chrootRoot, MS_BIND)  — bind chroot as separate FS
 3. mount(storeDir, storeDir, MS_BIND)      — bind store onto itself
 4. mount(storeDir, MS_SHARED)              — enable propagation for store
 5. For each /dev file: doBind()            — /dev/null, /dev/random, etc.
 6. For each pathInChroot: doBind()         — declared inputs + sandbox-paths
 7. mount("proc" on /proc)                  — new /proc
 8. mount("sysfs" on /sys)                  — new /sys (conditional)
 9. mount("tmpfs" on /dev/shm)              — tmpfs for shared memory
10. mount("devpts" on /dev/pts)             — pseudo-terminals
11. unshare(CLONE_NEWNS)                    — second mount namespace
12. pivot_root(".", "real-root")            — swap root
13. chroot(".")                             — belt and suspenders
14. umount2("real-root", MNT_DETACH)        — detach old root
```

**Bazel non-hermetic** (from [`linux-sandbox-pid1.cc:704-759`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L704-L759)):

```
 1. mount("/", MS_PRIVATE | MS_REC)        — cut off parent propagation
 2. For each -M/-m: mount(MS_BIND | MS_REC) — bind requested paths
 3. For each -e: mount("tmpfs")             — tmpfs on requested dirs
 4. For each -w: mount(MS_BIND | MS_REC)    — mark writable paths
 5. mount(working_dir, working_dir, MS_BIND) — working dir writable
 6. For each mount in /proc/self/mounts:    — remount everything read-only
       mount(MS_BIND | MS_REMOUNT | MS_RDONLY)  (except writable set)
 7. mount("proc" on /proc)                  — new /proc
 8. mount("sysfs" on /sys)                  — new /sys (conditional)
```

**Bazel hermetic** (from [`linux-sandbox-pid1.cc:729-735`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L729-L735)):

```
 1. mount("/", MS_PRIVATE | MS_REC)         — cut off parent propagation
 2. mount(sandbox_root, sandbox_root, MS_BIND) — bind sandbox root
 3. chdir(sandbox_root)                      — enter sandbox
 4. Create /dev + hard-link devices          — /dev/null, etc.
 5. mount("proc" on /proc)                   — new /proc
 6. mount("sysfs" on /sys)                   — new /sys (conditional)
 7. For each -e: mount("tmpfs")              — tmpfs on requested dirs
 8. mount(working_dir, working_dir, MS_BIND) — working dir writable
 9. For each -M/-m: CreateTarget + mount(MS_BIND | MS_RDONLY) — bind read-only
10. For each -w: mount(MS_BIND | MS_REC)     — mark writable paths
11. pivot_root(".", old_root)                 — swap root
12. chroot(".")                               — belt and suspenders
13. umount2(old_root, MNT_DETACH)             — detach old root
```

### 5.3 What's Visible Inside the Sandbox

| Path | Nix sandbox | Bazel non-hermetic | Bazel hermetic |
|------|-------------|-------------------|---------------|
| `/nix/store/...` (declared inputs) | Read-only | Read-only (if parent has them) | Only if `-M` mounted |
| `/nix/store/...` (undeclared) | **Not visible** | Read-only (if parent has them) | Not visible |
| `/lib64/ld-linux-x86-64.so.2` | Not visible (no FHS) | Visible if parent has it | Only if `-M` mounted |
| `/usr`, `/bin`, `/lib` | Not visible (no FHS) | Visible (read-only) | Not visible |
| `/proc` | Fresh mount | Fresh mount | Fresh mount |
| `/dev/null` etc. | Bind-mounted | Inherited from parent | Hard-linked |
| `/tmp` | Writable (chroot-local) | Depends on config | Depends on config |
| Build outputs dir | Writable | Writable (`-W`) | Writable (`-W`) |
| `/etc/resolv.conf` | Only for FODs | Inherited from parent | Only if `-M` mounted |

### 5.4 Design Philosophy Comparison

| Aspect | Nix | Bazel |
|--------|-----|-------|
| **Default policy** | Deny all, allow listed | Allow all, deny writes |
| **Filesystem assumption** | No assumption (builds from scratch) | FHS (assumes `/lib64`, `/usr`, etc. exist) |
| **Hermeticity scope** | All builds | Build actions only (not repo rules) |
| **Toolchain strategy** | Build from source or binary cache; all binaries have Nix store interpreter | Download pre-built FHS binaries |
| **Dynamic injection** | Yes (`MS_SHARED` + `setns`) | No |
| **Content addressing** | Store paths encode content hash | Action cache uses input hash |
| **Network policy** | Denied except for FODs | Denied except for repo rules |
| **Reproducibility check** | Re-build and compare output hashes | Trust the action cache |

---

## 6. The Composition Problem

### 6.1 What Happens When Bazel Runs Inside Nix

When Nix builds a derivation that invokes Bazel, the process hierarchy looks
like this:

```
Host kernel
  └─ Nix daemon
       └─ Nix sandbox (mount namespace 1)
            │  - / is a tmpfs-based chroot
            │  - /nix/store has only declared inputs (read-only)
            │  - /build is writable
            │  - No /lib64, no /usr, no /bin (except /bin/sh)
            │  - Network: only for FODs
            │
            └─ Bazel process
                 │  (repo rules: no additional sandboxing)
                 │
                 └─ Bazel linux-sandbox (mount namespace 2, for build actions)
                      │  mount("/", MS_PRIVATE | MS_REC)
                      │  Inherits Nix's sparse chroot as parent FS
                      │  Remounts everything read-only
                      │  - Still no /lib64, /usr, /bin
```

The fundamental issue: **Bazel inherits Nix's sparse chroot as its "full
filesystem."** In non-hermetic mode, Bazel assumes the parent filesystem is a
normal Linux system with FHS layout. Inside a Nix sandbox, that assumption
fails.

### 6.2 The ELF Interpreter Problem

Bazel's toolchain rules (`rules_python`, `rules_rust`, `rules_go`,
`toolchains_llvm`) download pre-built ELF binaries for the host platform. These
binaries have a hardcoded ELF interpreter path:

```
$ readelf -l python3.12 | grep interpreter
    [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
```

Inside a Nix sandbox, `/lib64/ld-linux-x86-64.so.2` does not exist. When Bazel
tries to execute these binaries, the kernel returns `ENOENT` ("No such file or
directory") — not because the binary file is missing, but because the **dynamic
linker** it requests is missing.

On a NixOS or Nix-managed system, binaries use Nix store paths as their
interpreter:

```
$ readelf -l /nix/store/...-python3-3.12.11/bin/python3 | grep interpreter
    [Requesting program interpreter: /nix/store/...-glibc-2.42/lib/ld-linux-x86-64.so.2]
```

This is the core incompatibility: Bazel downloads FHS binaries into a non-FHS
environment.

### 6.3 Repository Rules: The Hardest Case

Repository rules are the most problematic because:

1. **They download AND execute in the same invocation.** A rule like
   `rules_python`'s `python_repository` calls `repository_ctx.download_and_extract()`
   to fetch a pre-built Python, then immediately calls `repository_ctx.execute()`
   to run it. There is no hook between download and execution.

2. **They are not sandboxed by Bazel.** Repo rule execution goes through the
   `ProcessWrapper`, which only handles timeouts — no mount namespace, no
   filesystem isolation
   ([`StarlarkBaseExternalContext.java:2001-2006`](https://github.com/bazelbuild/bazel/blob/master/src/main/java/com/google/devtools/build/lib/bazel/repository/starlark/StarlarkBaseExternalContext.java#L2001-L2006)).

3. **They run inside Nix's sandbox.** When Bazel is invoked from a Nix
   derivation, repo rules execute inside Nix's sparse chroot — no `/lib64`,
   limited `/nix/store` visibility.

4. **Patching is fragile.** Using `patchelf` to fix the ELF interpreter works
   for already-extracted binaries, but Bazel re-creates repository rule outputs
   from cached archives on subsequent runs, wiping any patches.

---

## 7. Potential Changes to Improve Interoperability

Neither system is "wrong" — they solve different problems with different
trade-offs. But targeted changes on either side could make them compose better.

### 7.1 Changes on the Bazel Side

#### 7.1.1 Repository Rule Execution Wrapper

**What**: Add a `--repo_exec_wrapper=/path/to/script` flag that wraps every
`repository_ctx.execute()` call.

**How it helps**: The wrapper script could `patchelf` downloaded ELF binaries
before executing them, or set up a mini-FHS environment.

**Implementation**: ~100 lines of Java in
[`StarlarkBaseExternalContext.java`](https://github.com/bazelbuild/bazel/blob/master/src/main/java/com/google/devtools/build/lib/bazel/repository/starlark/StarlarkBaseExternalContext.java).
Prepend the wrapper path to the argument list before passing to
`StarlarkExecutionResult.builder()`.

**Trade-offs**: Simple, general-purpose (not Nix-specific), easy to upstream.
But it's a workaround — it doesn't address the architectural mismatch.

#### 7.1.2 Detect and Skip Redundant Sandboxing

**What**: When Bazel detects it's already running inside an external sandbox
(Nix, Docker, etc.), optionally skip its own linux-sandbox for build actions.

**How it helps**: Eliminates the nested namespace problem entirely. Nix's
sandbox provides the isolation guarantees; Bazel's sandbox is redundant.

**Detection**: Check for the presence of `/nix/store` or a `NIX_BUILD_TOP`
environment variable. Or provide a flag: `--sandbox_strategy=external`.

**Trade-offs**: Loses Bazel's per-action isolation (undeclared dependencies
between actions could go undetected). But when running inside Nix, the
per-derivation isolation is already strict.

#### 7.1.3 Sandbox-Aware FHS Compatibility Layer

**What**: When Bazel's linux-sandbox sets up its mount namespace, optionally
bind-mount a user-provided library directory at `/lib64` to satisfy downloaded
ELF binaries.

**Implementation**: Extend the existing `--sandbox_add_mount_pair` flag or add
a dedicated `--sandbox_fhs_lib_dir` flag. Apply the mount in both
`MountFilesystems()` and `MountAllMounts()` in
[`linux-sandbox-pid1.cc`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc).

**Trade-offs**: Solves the problem for build actions, but not for repository
rules (which don't use linux-sandbox).

#### 7.1.4 Post-Extract Hook for Downloaded Archives

**What**: Add a `--repo_post_extract_command` flag that runs after every
`repository_ctx.download_and_extract()` call.

**How it helps**: A `patchelf` command could fix ELF interpreters immediately
after extraction, before the repository rule tries to execute them.

**Implementation**: ~50 lines in
[`StarlarkBaseExternalContext.java`](https://github.com/bazelbuild/bazel/blob/master/src/main/java/com/google/devtools/build/lib/bazel/repository/starlark/StarlarkBaseExternalContext.java)
around
[the download_and_extract method](https://github.com/bazelbuild/bazel/blob/master/src/main/java/com/google/devtools/build/lib/bazel/repository/starlark/StarlarkBaseExternalContext.java#L886).

**Trade-offs**: Targeted at exactly the right point (between download and
execution), but requires Bazel to support running arbitrary commands during
repo rule evaluation.

#### 7.1.5 Make `MS_PRIVATE` Configurable

**What**: Allow Bazel's sandbox to use `MS_SLAVE` instead of `MS_PRIVATE` on
the root mount, so that parent namespace mounts (like Nix's `/nix/store`
additions via `MS_SHARED`) propagate into Bazel's sandbox.

**Implementation**: One-line change in
[`linux-sandbox-pid1.cc:205`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L205):
```cpp
// Instead of:
mount(nullptr, "/", nullptr, MS_REC | MS_PRIVATE, nullptr);
// Optionally:
mount(nullptr, "/", nullptr, MS_REC | MS_SLAVE, nullptr);
```

**Trade-offs**: `MS_SLAVE` allows parent-to-child mount propagation but not
child-to-parent. This preserves Bazel's isolation while allowing the parent
(Nix) to inject paths. However, it changes Bazel's security model — the parent
namespace can now influence the build environment.

### 7.2 Changes on the Nix Side

#### 7.2.1 FHS Compatibility Layer in Sandbox

**What**: Optionally bind-mount a glibc/FHS compatibility layer at `/lib64`
inside the Nix build sandbox.

**How it helps**: Downloaded ELF binaries could find their interpreter without
patching. Nix already provides `/bin/sh` via `sandbox-paths`; providing
`/lib64/ld-linux-x86-64.so.2` would be an extension of the same concept.

**Implementation**: Add to `sandbox-paths` in `nix.conf`:
```
sandbox-paths = /lib64=${glibc}/lib
```

Or implement as a per-derivation option.

**Trade-offs**: Introduces FHS paths into the sandbox, which could mask
undeclared dependencies on FHS layout. This conflicts with Nix's philosophy
of explicit dependency declaration. Could be made opt-in via a derivation
attribute.

#### 7.2.2 Expose More Libraries via `sandbox-paths`

**What**: For derivations that build Bazel projects, automatically include
a broader set of libraries (glibc, zlib, libstdc++, openssl) in the sandbox.

**Implementation**: Use `extra-sandbox-paths` or a pre-build hook to inject
library paths based on derivation attributes.

**Trade-offs**: Makes the sandbox less hermetic. Better suited as a per-project
configuration than a system-wide default.

#### 7.2.3 Allow Nested User Namespaces

**What**: Ensure the Nix sandbox doesn't prevent nested `clone(CLONE_NEWUSER)`
calls, so that Bazel's own sandbox can function inside Nix's.

**Current state**: This generally works on modern kernels with
`/proc/sys/user/max_user_namespaces` set appropriately. The main limitation is
that bubblewrap-style nested sandboxing may not function because the Nix
sandbox's root is read-only, preventing creation of new mount points.

**Trade-offs**: Allowing nested namespaces doesn't violate Nix's security
model, since the inner namespace can only further restrict access. But it
doesn't solve the FHS binary problem by itself.

### 7.3 Changes in the Bazel Rule Ecosystem

Many of the compatibility issues could be addressed in individual Bazel rule
sets without changing either Nix or Bazel core:

#### 7.3.1 Support System-Provided Toolchains

**What**: Allow `rules_python`, `rules_rust`, `rules_go`, and `toolchains_llvm`
to use locally-installed toolchains instead of downloading pre-built binaries.

**Current state**: `rules_python` has `local_runtime_repo` since v1.4.0.
`rules_rust` accepts `CARGO_BAZEL_GENERATOR_URL` for cargo-bazel but still
downloads its own `rustc`/`cargo`. `rules_go` has `go_host_sdk`. These
mechanisms are inconsistent and often incomplete.

**Ideal**: Each rule set provides a `use_system_toolchain()` option that
accepts an absolute path and skips the download entirely.

#### 7.3.2 Content-Addressed Toolchain Downloads

**What**: Instead of URL-addressed downloads (where the binary format is
assumed), provide content-addressed toolchain downloads with format metadata.

**How it helps**: If the download metadata included the ELF interpreter path
and required shared libraries, a build system could verify compatibility
before attempting execution.

---

## 8. Summary

Nix and Bazel use the same Linux kernel primitives to achieve build
isolation, but with different default postures:

| | Nix | Bazel |
|--|-----|-------|
| **Starts with** | Empty filesystem | Full filesystem |
| **Primary control** | What's *visible* | What's *writable* |
| **Binary format** | Nix store paths (content-addressed) | FHS paths (convention-based) |
| **Toolchains** | Built from source or Nix binary cache | Downloaded as pre-built FHS binaries |

The composition problem arises specifically because Bazel downloads FHS binaries
into Nix's non-FHS sandbox. The kernel primitives are compatible — both systems
use the same `clone()` flags and `mount()` operations. The incompatibility is at
the **userspace convention layer**: what paths binaries expect to exist.

The most promising path forward involves changes on multiple fronts:

1. **Bazel core**: Add a mechanism to intercept binary execution in repository
   rules (post-extract hook or execution wrapper), so that ELF interpreters can
   be fixed before first use.

2. **Bazel rules**: Improve support for system-provided toolchains, reducing
   dependence on FHS-assuming pre-built downloads.

3. **Nix ecosystem**: Provide optional FHS compatibility layers for derivations
   that build with Bazel, acknowledging that Bazel's toolchain model is FHS-native.

4. **Both sides**: Explore making `MS_SHARED` / `MS_SLAVE` propagation
   configurable, so parent sandboxes can inject paths into child sandboxes
   without breaking isolation guarantees.

The deeper insight is that Nix and Bazel are **complementary**, not competitive.
Nix excels at deterministic, content-addressed package management and
environment provisioning. Bazel excels at fast, incremental, fine-grained build
execution with remote caching. A well-integrated combination — where Nix
provides toolchains and Bazel orchestrates builds — would be more powerful than
either system alone.

---

*This document was written while working on Nix packaging for
[Redpanda](https://github.com/redpanda-data/redpanda), a Kafka-compatible
streaming platform built with Bazel. Source references are based on
[Nix](https://github.com/NixOS/nix) and
[Bazel](https://github.com/bazelbuild/bazel) as of early 2026.*
