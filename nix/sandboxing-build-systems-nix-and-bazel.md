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
  - [6.2 What Happens When Nix Runs Inside Bazel](#62-what-happens-when-nix-runs-inside-bazel)
  - [6.3 The ELF Interpreter Problem](#63-the-elf-interpreter-problem)
  - [6.4 Repository Rules: The Hardest Case](#64-repository-rules-the-hardest-case)
  - [6.5 Why "Just Mount /nix/store" Isn't Enough](#65-why-just-mount-nixstore-isnt-enough)
  - [6.6 Why Not Just Use the System Python?](#66-why-not-just-use-the-system-python)
- [7. Potential Changes to Improve Interoperability](#7-potential-changes-to-improve-interoperability)
  - [7.1 Changes on the Bazel Side](#71-changes-on-the-bazel-side)
  - [7.2 Changes on the Nix Side](#72-changes-on-the-nix-side)
  - [7.3 Changes in the Bazel Rule Ecosystem](#73-changes-in-the-bazel-rule-ecosystem)
- [8. Summary](#8-summary)
- [9. Implementation: Patching rules_python to Use Nix-Provided Python](#9-implementation-patching-rules_python-to-use-nix-provided-python)
  - [9.1 Goal](#91-goal)
  - [9.2 The Code Path Today](#92-the-code-path-today)
  - [9.3 What Already Exists](#93-what-already-exists)
  - [9.4 The Patch: Add `local_toolchain` Tag Class](#94-the-patch-add-local_toolchain-tag-class)
  - [9.5 Usage in Redpanda's MODULE.bazel](#95-usage-in-redpandas-modulebazel)
  - [9.6 Files Changed in rules_python](#96-files-changed-in-rules_python)

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

### 6.2 What Happens When Nix Runs Inside Bazel

The reverse composition — running Nix build commands from within a Bazel build
action — fails for different but equally fundamental reasons.

```
Host kernel (standard FHS Linux, or NixOS)
  └─ Bazel linux-sandbox (mount namespace)
       │  - / is parent FS (non-hermetic) or empty (hermetic)
       │  - Most paths are read-only
       │  - No network access
       │  - No /nix/var/nix/db (Nix database)
       │  - No Nix daemon socket (/nix/var/nix/daemon-socket)
       │
       └─ nix-build or nix-store
            ✗ Cannot contact Nix daemon (socket not mounted, or read-only)
            ✗ Cannot write to /nix/store (read-only in sandbox)
            ✗ Cannot create mount namespaces (nested CLONE_NEWNS may fail)
            ✗ No network for fetching sources
```

The problems are:

1. **No Nix daemon access.** Nix builds are coordinated by the Nix daemon
   (`nix-daemon`), which listens on a Unix socket at
   `/nix/var/nix/daemon-socket/socket`. Bazel's sandbox does not mount this
   socket, and even if it did, the daemon runs outside the sandbox and cannot
   see the sandbox's mount namespace.

2. **`/nix/store` is read-only.** Nix needs write access to `/nix/store` to
   create build outputs. In Bazel's non-hermetic mode, `/nix/store` is
   remounted read-only by
   [`MakeFilesystemMostlyReadOnly()`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L362-L433).
   You could add `--sandbox_writable_path=/nix/store` to fix this, but that
   alone doesn't solve the daemon problem.

3. **No network.** Bazel build actions don't have network access (unless
   explicitly configured). Nix derivations that need to fetch sources would
   fail.

4. **Nested namespaces may fail.** Nix's sandbox creates its own mount, PID,
   and user namespaces via `clone()`. Depending on kernel configuration
   (`/proc/sys/user/max_user_namespaces`) and the capabilities available inside
   Bazel's sandbox, this `clone()` call may fail with `EPERM`.

5. **Nix database is inaccessible.** Nix tracks all store paths in a SQLite
   database at `/nix/var/nix/db/`. Without access to this database, Nix cannot
   determine what's already built or register new outputs.

In short: while running Bazel inside Nix fails at the **binary format** level
(FHS ELF interpreters), running Nix inside Bazel fails at the **infrastructure**
level (daemon, database, store write access, network). The Nix daemon is a
system service that expects to be the outermost authority over `/nix/store`, not
a guest inside another sandbox.

The viable alternative for this direction is
[`rules_nixpkgs`](https://github.com/tweag/rules_nixpkgs), which runs Nix
*before* Bazel (in the host environment) to provision toolchains, then passes
the resulting Nix store paths into Bazel as repository rule outputs.

### 6.3 The ELF Interpreter Problem

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

### 6.4 Repository Rules: The Hardest Case

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

### 6.5 Why "Just Mount /nix/store" Isn't Enough

A natural first reaction: "If the problem is that Bazel's sandbox can't see
Nix paths, why not add `/nix/store` to the sandbox with
`--sandbox_add_mount_pair=/nix/store`?"

This is a good instinct, but it only partially addresses the problem. To
understand why, we need to consider three different Bazel execution contexts
and what each one needs:

#### Build actions (sandboxed)

Bazel's linux-sandbox creates a mount namespace for each build action. In
**non-hermetic mode** (the default), the entire parent filesystem is already
visible — including `/nix/store` if it exists. The
[`MakeFilesystemMostlyReadOnly()`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L362-L433)
pass remounts it read-only, but it remains visible. No extra flags needed.

In **hermetic mode**, yes, you would need `--sandbox_add_mount_pair=/nix/store`
to make it visible.

But visibility of `/nix/store` doesn't help downloaded FHS binaries. Those
binaries have `/lib64/ld-linux-x86-64.so.2` hardcoded as their ELF interpreter.
What you'd actually need is:

```
--sandbox_add_mount_pair=/nix/store/...-glibc-2.42/lib:/lib64
```

This would mount Nix's glibc at the FHS path `/lib64`, making the dynamic
linker available where downloaded binaries expect it. This **does work** for
build actions. The
[`ShouldBeWritable()`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc#L336-L358)
function only controls write access — read-only visibility is the default for
all mounts.

The writable set in non-hermetic mode consists of exactly:
- The working directory (`-W`)
- Paths marked with `--sandbox_writable_path` (`-w`)
- Paths marked with `--sandbox_tmpfs_path` (`-e`)
- `/dev/pts` (if PTY mode is enabled)

`/nix/store` doesn't need to be writable — read-only is correct.

#### Build actions with `--spawn_strategy=local`

When `--spawn_strategy=local` is set (as in the
[Redpanda Nix build](https://github.com/redpanda-data/redpanda)), Bazel skips
the linux-sandbox entirely. Build actions run directly in the parent process's
mount namespace — which, inside a Nix derivation, is Nix's sandbox. No
`--sandbox_add_mount_pair` applies because there is no Bazel sandbox to
configure.

#### Repository rules (never sandboxed)

This is where the approach breaks down completely. Repository rules **never**
use the linux-sandbox.
[`--sandbox_add_mount_pair`](https://github.com/bazelbuild/bazel/blob/master/src/main/java/com/google/devtools/build/lib/sandbox/SandboxOptions.java)
has no effect on them. Repository rules run via
[`ProcessWrapper`](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/process-wrapper.cc),
which is just a thin timeout wrapper with no mount namespace.

When Bazel is inside a Nix sandbox, repo rules see Nix's sparse chroot
directly. There is no Bazel-level mount table to add `/nix/store` or `/lib64`
to. The only way to get `/lib64` into the environment is to either:

1. Add it to Nix's sandbox (via `sandbox-paths` in `nix.conf` or derivation
   inputs)
2. Use `patchelf` to rewrite the binary's interpreter to a Nix store path
3. Intercept execution in Bazel before `execvp()` is called

This is why targeted changes to either Bazel's repo rule execution path or
Nix's sandbox configuration are needed — sandbox mount flags alone cannot
solve the problem.

### 6.6 Why Not Just Use the System Python?

A deeper question: repository rules don't use Bazel's sandbox — they run
directly in the parent environment. Inside a Nix sandbox, tools like `python3`
are on PATH and have proper Nix store ELF interpreters. If Bazel's repo rules
just called `python3` and let the environment resolve it, everything would
"just work." No `/lib64` needed, no patchelf needed. Why doesn't this happen?

The answer is that **Bazel toolchain rules download their own binaries by
design, regardless of what's available on PATH.** This is a philosophical
choice, not a technical limitation.

#### The `python.toolchain()` decision tree

When a MODULE.bazel file contains:

```starlark
python = use_extension("@rules_python//python/extensions:python.bzl", "python")
python.toolchain(python_version = "3.12")
```

The code path is unconditional:

1. [`python.bzl:215`](https://github.com/bazelbuild/rules_python/blob/main/python/private/python.bzl#L215)
   — `_python_impl()` processes the toolchain tag
2. Calls `python_register_toolchains()` in
   [`python_register_toolchains.bzl:37`](https://github.com/bazelbuild/rules_python/blob/main/python/private/python_register_toolchains.bzl#L37)
3. For each platform with a sha256 in `TOOL_VERSIONS`, creates a
   `python_repository()` rule that calls `rctx.download_and_extract()` in
   [`python_repository.bzl:76-88`](https://github.com/bazelbuild/rules_python/blob/main/python/private/python_repository.bzl#L76-L88)

There is no `interpreter_path` parameter on `python.toolchain()`. No
environment variable to skip the download. No "check if python3 is already
available" logic. It always downloads a pre-built CPython from
python-build-standalone — an FHS binary with `/lib64/ld-linux-x86-64.so.2`
hardcoded as its ELF interpreter.

#### `local_runtime_repo` exists but isn't wired up

rules_python *does* have a mechanism for using a system Python:
[`local_runtime_repo`](https://github.com/bazelbuild/rules_python/blob/main/python/private/local_runtime_repo.bzl#L108),
added in v1.4.0. It does exactly the right thing — resolves `python3` via PATH:

[`local_runtime_repo.bzl:358`](https://github.com/bazelbuild/rules_python/blob/main/python/private/local_runtime_repo.bzl#L358)
```python
interpreter_path = rctx.attr.interpreter_path or "python3"
if "/" not in interpreter_path:
    result = repo_utils.which_unchecked(rctx, interpreter_path)
```

In a Nix sandbox with `python3` on PATH, this would find
`/nix/store/...-python3-3.12/bin/python3` — a binary with a Nix store ELF
interpreter. No `/lib64` needed. No patchelf needed. It would just work.

**But `local_runtime_repo` is only available as a WORKSPACE macro** (via
[`python/local_toolchains/repos.bzl`](https://github.com/bazelbuild/rules_python/blob/main/python/local_toolchains/repos.bzl)).
It is not exposed through the `python` module extension. There is no
`python.local_toolchain()` tag class. It cannot be used from MODULE.bazel.

#### `pip.parse()` already does the right thing (almost)

The `pip.parse()` extension, which runs `pip` to resolve Python package
dependencies, has a simpler fallback:

[`pip_repository.bzl:38-53`](https://github.com/bazelbuild/rules_python/blob/main/python/private/pypi/pip_repository.bzl#L38-L53)
```python
def _get_python_interpreter_attr(rctx):
    if rctx.attr.python_interpreter:
        return rctx.attr.python_interpreter
    if "win" in rctx.os.name:
        return "python.exe"
    else:
        return "python3"
```

If `python3` is on PATH, this works — it just calls `python3` and lets the
environment resolve it. In a Nix sandbox, this would use the Nix-provided
Python. But in practice, `pip.parse()` is typically configured to use the
interpreter from the downloaded `python_3_12_host` repo, so when that repo
fails, `pip.parse()` fails too.

#### The same pattern across all toolchain rules

This isn't unique to rules_python. The same download-first pattern appears in
every major Bazel toolchain rule:

| Rule set | Downloads | System alternative |
|----------|-----------|-------------------|
| `rules_python` | CPython from python-build-standalone | `local_runtime_repo` (WORKSPACE only, not MODULE.bazel) |
| `rules_rust` | cargo, rustc, rust-std from static.rust-lang.org | No system alternative in MODULE.bazel |
| `rules_go` | Go toolchain from golang.org | `go_host_sdk` (WORKSPACE only) |
| `toolchains_llvm` | LLVM/Clang pre-built tarballs | No system alternative |

In every case, the rule downloads an FHS binary. In every case, a system
alternative either doesn't exist or exists only for WORKSPACE (not
MODULE.bazel). And in every case, the Nix-provided version of the same tool
would work without any FHS compatibility layer.

#### What would fix this

The fix is surprisingly small for each rule set — expose the existing local
toolchain mechanism through the module extension:

**For rules_python**: Add a `python.local_toolchain()` tag class that creates a
`local_runtime_repo` instead of a `python_repository`:

```starlark
python.local_toolchain(
    python_version = "3.12",
    interpreter_path = "python3",  # resolved via PATH at repo rule time
)
```

This would benefit NixOS, Guix, any system with a package-manager-provided
Python, and CI environments where Python is pre-installed. It requires no
changes to Bazel core — only to the rule set.

**For rules_rust**: Accept `CARGO` and `RUSTC` environment variables in the
`rust.toolchain()` extension, or add a `rust.local_toolchain()` that uses
system-provided Rust.

**For rules_go**: `go_host_sdk` already exists for WORKSPACE; expose it
through the `go_sdk` module extension.

**For toolchains_llvm**: Accept a system-provided LLVM via a module extension
tag.

These are rule-level changes, not Bazel core changes. They don't compromise
Bazel's hermeticity model — the toolchain is still declared, just resolved
from the environment rather than downloaded. And they align with how Nix
already provides these tools: as content-addressed store paths with correct
ELF interpreters, available on PATH.

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

## 9. Implementation: Patching rules_python to Use Nix-Provided Python

This section documents the concrete patch to `rules_python` (v1.5.1) that
wires up the existing `local_runtime_repo` mechanism through the MODULE.bazel
extension, so that `python.local_toolchain()` can be used instead of (or
alongside) `python.toolchain()`.

### 9.1 Goal

Make Bazel call the Nix-provided `python3` (resolved via `PATH` to a
`/nix/store/...` path) instead of downloading a pre-built CPython binary with
a hardcoded `/lib64/ld-linux-x86-64.so.2` ELF interpreter.

We don't care whether Bazel still *downloads* the FHS binary — we care that
when it *executes* Python (for pip, for build scripts, for tests), it uses
the Nix-provided one.

### 9.2 The Code Path Today

When MODULE.bazel contains `python.toolchain(python_version = "3.12")`, the
call chain is:

```
MODULE.bazel
  └─ python.toolchain(python_version = "3.12")
       └─ _python_impl()                          # python/private/python.bzl:215
            └─ python_register_toolchains()        # python/private/python_register_toolchains.bzl
                 └─ for each platform:
                      python_repository()          # python/private/python_repository.bzl
                        ├─ rctx.download_and_extract()   # downloads FHS CPython
                        └─ py_runtime(interpreter = "bin/python3")  # points to downloaded binary
```

Every step is unconditional. There is no `interpreter_path` parameter, no
environment variable override, no "check if python3 is on PATH" logic.

### 9.3 What Already Exists

rules_python v1.5.1 already has all the pieces for local Python toolchains,
just not wired to MODULE.bazel:

| Component | File | What it does |
|-----------|------|--------------|
| `local_runtime_repo` | `python/private/local_runtime_repo.bzl:230` | Repository rule that discovers a system Python. Calls `which python3` (or uses a provided path), queries it for version/ABI/library info, generates a `py_runtime` with `interpreter_path` pointing to the resolved binary. |
| `_resolve_interpreter_path` | `python/private/local_runtime_repo.bzl:339` | The PATH lookup logic. If the value has no slashes, calls `repo_utils.which_unchecked(rctx, interpreter_path)`. In a Nix sandbox, this resolves to `/nix/store/...-python3-3.12.x/bin/python3`. |
| `local_runtime_toolchains_repo` | `python/private/local_runtime_toolchains_repo.bzl:51` | Creates `toolchain()` definitions that point at a `local_runtime_repo`. Supports both version-aware and version-unaware registration. |
| `define_local_runtime_toolchain_impl` | `python/private/local_runtime_repo_setup.bzl` | Generates the `BUILD.bazel` inside a local runtime repo with `py_runtime(interpreter_path = "/nix/store/.../bin/python3")`. |

The gap is in `python/private/python.bzl` — the module extension's
`tag_classes` dict (line 1352, unpatched) has no `local_toolchain` entry. The
`_python_impl()` function (line 215) only processes `toolchain` tags and
always calls `python_register_toolchains()`, which always calls
`python_repository()`, which always downloads.

### 9.4 The Patch

The patch modifies a single file: `python/private/python.bzl`. It was applied
to a branch (`nix-local-toolchain`) based on the `1.5.1` tag. Four changes:

#### 9.4.1 New imports (lines 21–22)

```starlark
load(":local_runtime_repo.bzl", "local_runtime_repo")
load(":local_runtime_toolchains_repo.bzl", "local_runtime_toolchains_repo")
```

These symbols already exist in the rules_python codebase but were not
imported by the module extension file.

#### 9.4.2 Processing logic in `_python_impl()` (lines 507–525)

Inserted after the `multi_toolchain_aliases()` call and before the
`debug_info` check:

```starlark
    # Process local_toolchain tags: create repos backed by a system-provided
    # Python interpreter (e.g. one provided by Nix) instead of downloading
    # a pre-built binary.
    for mod in module_ctx.modules:
        for tag in mod.tags.local_toolchain:
            repo_name = "local_python_{}".format(
                tag.python_version.replace(".", "_"),
            )
            local_runtime_repo(
                name = repo_name,
                interpreter_path = tag.interpreter_path,
                on_failure = tag.on_failure,
            )
            toolchains_repo_name = repo_name + "_toolchains"
            local_runtime_toolchains_repo(
                name = toolchains_repo_name,
                runtimes = [repo_name],
            )
```

For each `local_toolchain` tag, this creates two repos:
- `local_python_3_12` — a `local_runtime_repo` that discovers the system
  Python and generates a `py_runtime` with `interpreter_path`
- `local_python_3_12_toolchains` — a `local_runtime_toolchains_repo` that
  creates `toolchain()` targets pointing at the runtime repo

#### 9.4.3 New `_local_toolchain` tag class (line 1107)

```starlark
_local_toolchain = tag_class(
    doc = """Tag class to register a local (system-provided) Python as a toolchain.
    ...
    """,
    attrs = {
        "interpreter_path": attr.string(default = "python3", ...),
        "on_failure": attr.string(default = "warn", values = ["skip", "warn", "fail"], ...),
        "python_version": attr.string(mandatory = True, ...),
    },
)
```

Three attributes:
- `interpreter_path` — bare name (looked up on `PATH`) or absolute path;
  defaults to `"python3"`
- `on_failure` — `"skip"` (silent fallback), `"warn"` (log + fallback),
  or `"fail"` (hard error); defaults to `"warn"`
- `python_version` — mandatory, e.g. `"3.12"`

#### 9.4.4 Extension registration (lines 960, 1421)

Added `"local_toolchain": _local_toolchain` to the `tag_classes` dict
(line 1421) and `"PATH"` to the `environ` list (line 960) so the extension
re-evaluates when PATH changes.

### 9.5 Consuming the Patch

#### Redpanda's MODULE.bazel

```starlark
bazel_dep(name = "rules_python", version = "1.5.1")
local_path_override(
    module_name = "rules_python",
    path = "/home/das/Downloads/rules_python",
)

python = use_extension("@rules_python//python/extensions:python.bzl", "python", dev_dependency = True)
python.toolchain(
    ignore_root_user_error = True,
    is_default = True,
    python_version = "3.12",
)
python.local_toolchain(
    python_version = "3.12",
    interpreter_path = "python3",
)
use_repo(python, "local_python_3_12", "local_python_3_12_toolchains")
register_toolchains("@local_python_3_12_toolchains//:all")
```

The `python.toolchain()` line stays — it is needed for non-Nix builds and
provides the download-based fallback. The `local_toolchain` takes precedence
when a local Python is found (via `register_toolchains` ordering). When no
local Python is found (e.g. on a non-Nix CI machine), `on_failure = "warn"`
causes it to generate an incompatible-platform stub, and the downloaded
toolchain is used instead.

#### Nix dev shell (`nix/shell.nix`)

The dev shell was updated to use `bazelisk` (which reads `.bazelversion` to
select Bazel 8.4.1) and includes `python312` on PATH.

### 9.6 Outcome

Tested inside `nix develop` on the Redpanda repository:

```
$ bazelisk query --output=build @local_python_3_12//:_py3_runtime
```

```starlark
py_runtime(
  name = "_py3_runtime",
  implementation_name = "cpython",
  interpreter_path = "/nix/store/flbw79qdmvzbdrafd93avy5a7d29m2vb-python3-3.12.12/bin/python3",
  interpreter_version_info = {"major": "3", "micro": "12", "minor": "12"},
  python_version = "PY3",
)
```

The toolchain resolved `python3` via PATH to the Nix store path. The
generated `py_runtime` uses `interpreter_path` (a platform runtime) rather
than `interpreter` (a hermetic/in-build runtime), meaning:

- **No FHS binary downloaded and executed** — the Nix-provided Python is
  used directly
- **No `/lib64/ld-linux-x86-64.so.2` needed** — the binary has a Nix store
  ELF interpreter
- **No patchelf needed** — nothing to patch
- **Build succeeds**: `bazelisk build @local_python_3_12//:python_runtimes`
  completes with no errors

The `@local_python_3_12_toolchains` repo generates six toolchain targets
(version-aware and version-unaware variants for runtime, exec tools, and
cc toolchain):

```
@local_python_3_12_toolchains//:0000_toolchain
@local_python_3_12_toolchains//:0000_py_cc_toolchain
@local_python_3_12_toolchains//:0000_py_exec_tools_toolchain
@local_python_3_12_toolchains//:0001_default_toolchain
@local_python_3_12_toolchains//:0001_default_py_cc_toolchain
@local_python_3_12_toolchains//:0001_default_py_exec_tools_toolchain
```

### 9.7 Files Changed Summary

| File | Lines (patched) | Change |
|------|-----------------|--------|
| `python/private/python.bzl:21-22` | 2 lines added | Import `local_runtime_repo` and `local_runtime_toolchains_repo` |
| `python/private/python.bzl:507-525` | 19 lines added | Processing loop for `local_toolchain` tags in `_python_impl()` |
| `python/private/python.bzl:960` | 1 line changed | Add `"PATH"` to `environ` list |
| `python/private/python.bzl:1107-1153` | 47 lines added | `_local_toolchain` tag class definition |
| `python/private/python.bzl:1421` | 1 line added | Register `"local_toolchain"` in `tag_classes` dict |
| **Total** | **70 lines** | One file changed, zero new files |

No other files in rules_python are modified. The patch exclusively wires
existing, tested code (`local_runtime_repo`, `local_runtime_toolchains_repo`)
into the module extension system.

---

*This document was written while working on Nix packaging for
[Redpanda](https://github.com/redpanda-data/redpanda), a Kafka-compatible
streaming platform built with Bazel. Source references are based on
[Nix](https://github.com/NixOS/nix) and
[Bazel](https://github.com/bazelbuild/bazel) as of early 2026.*
