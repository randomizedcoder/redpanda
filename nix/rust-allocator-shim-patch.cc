// ── Complete Rust allocator shim for Rust 1.89+ with Nix toolchain ──
//
// Rust 1.89+ (rust-lang/rust#128135) moved allocator symbols into the
// __rustc:: namespace using Rust v0 name mangling. The stdlib's __rdl_*
// implementations are also mangled. Rather than chasing mangled symbol
// names (which are compiler-version-specific), this shim implements
// the allocator functions directly using the system allocator.
//
// This file REPLACES the original rules_rust allocator_library.cc.
// It provides both the old-style (__rust_alloc) and new-style
// (__rustc::__rust_alloc via Rust v0 mangling) symbols.

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ── System allocator helpers ──
// These match the semantics of Rust's default allocator (__rdl_*),
// which delegates to the system allocator with alignment support.

static uint8_t *sys_alloc(uintptr_t size, uintptr_t align) {
    return static_cast<uint8_t *>(aligned_alloc(align, size));
}

static void sys_dealloc(uint8_t *ptr, uintptr_t, uintptr_t) {
    free(ptr);
}

static uint8_t *sys_realloc(uint8_t *ptr, uintptr_t old_size,
                            uintptr_t align, uintptr_t new_size) {
    if (align <= alignof(max_align_t)) {
        return static_cast<uint8_t *>(realloc(ptr, new_size));
    }
    // For over-aligned allocations, realloc can't guarantee alignment.
    uint8_t *new_ptr = static_cast<uint8_t *>(aligned_alloc(align, new_size));
    if (new_ptr) {
        uintptr_t copy_size = old_size < new_size ? old_size : new_size;
        memcpy(new_ptr, ptr, copy_size);
        free(ptr);
    }
    return new_ptr;
}

static uint8_t *sys_alloc_zeroed(uintptr_t size, uintptr_t align) {
    uint8_t *ptr = sys_alloc(size, align);
    if (ptr) {
        memset(ptr, 0, size);
    }
    return ptr;
}

[[noreturn]] static void sys_alloc_error_handler(uintptr_t, uintptr_t) {
    abort();
}

// ── Old-style symbols (pre-1.89 Rust / rules_rust 0.60.0) ──

extern "C" __attribute__((weak))
uint8_t *__rust_alloc(uintptr_t size, uintptr_t align) {
    return sys_alloc(size, align);
}

extern "C" __attribute__((weak))
void __rust_dealloc(uint8_t *ptr, uintptr_t size, uintptr_t align) {
    sys_dealloc(ptr, size, align);
}

extern "C" __attribute__((weak))
uint8_t *__rust_realloc(uint8_t *ptr, uintptr_t old_size,
                        uintptr_t align, uintptr_t new_size) {
    return sys_realloc(ptr, old_size, align, new_size);
}

extern "C" __attribute__((weak))
uint8_t *__rust_alloc_zeroed(uintptr_t size, uintptr_t align) {
    return sys_alloc_zeroed(size, align);
}

extern "C" __attribute__((weak))
void __rust_alloc_error_handler(uintptr_t size, uintptr_t align) {
    sys_alloc_error_handler(size, align);
}

__attribute__((weak)) uint8_t __rust_alloc_error_handler_should_panic = 0;
__attribute__((weak)) uint8_t __rust_no_alloc_shim_is_unstable = 0;

// ── New-style symbols (Rust 1.89+, __rustc:: namespace, v0 mangling) ──
// These are the exact mangled names the stdlib references.
// Crate hash CsbGziBcbGa3B corresponds to the __rustc crate.

// __rustc::__rust_alloc
extern "C" __attribute__((weak))
uint8_t *_RNvCsbGziBcbGa3B_7___rustc12___rust_alloc(uintptr_t size,
                                                      uintptr_t align) {
    return sys_alloc(size, align);
}

// __rustc::__rust_dealloc
extern "C" __attribute__((weak))
void _RNvCsbGziBcbGa3B_7___rustc14___rust_dealloc(uint8_t *ptr,
                                                    uintptr_t size,
                                                    uintptr_t align) {
    sys_dealloc(ptr, size, align);
}

// __rustc::__rust_realloc
extern "C" __attribute__((weak))
uint8_t *_RNvCsbGziBcbGa3B_7___rustc14___rust_realloc(uint8_t *ptr,
                                                        uintptr_t old_size,
                                                        uintptr_t align,
                                                        uintptr_t new_size) {
    return sys_realloc(ptr, old_size, align, new_size);
}

// __rustc::__rust_alloc_zeroed
extern "C" __attribute__((weak))
uint8_t *_RNvCsbGziBcbGa3B_7___rustc19___rust_alloc_zeroed(uintptr_t size,
                                                             uintptr_t align) {
    return sys_alloc_zeroed(size, align);
}

// __rustc::__rust_alloc_error_handler
extern "C" __attribute__((weak))
void _RNvCsbGziBcbGa3B_7___rustc26___rust_alloc_error_handler(
    uintptr_t size, uintptr_t align) {
    sys_alloc_error_handler(size, align);
}

// __rustc::__rust_alloc_error_handler_should_panic_v2
extern "C" __attribute__((weak))
uint8_t _RNvCsbGziBcbGa3B_7___rustc42___rust_alloc_error_handler_should_panic_v2 = 0;

// __rustc::__rust_no_alloc_shim_is_unstable_v2
extern "C" __attribute__((weak))
uint8_t _RNvCsbGziBcbGa3B_7___rustc35___rust_no_alloc_shim_is_unstable_v2 = 0;
