/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 
 * Copyright (C) 2025 Liankong (xhsw.new@outlook.com). All Rights Reserved.
 * 本代码由GPL-2授权
 * 
 * 适配KernelSU的KPM 内核模块加载器兼容实现
 * 
 * 集成了 ELF 解析、内存布局、符号处理、重定位（支持 ARM64 重定位类型）
 * 并参照KernelPatch的标准KPM格式实现加载和控制
 */

#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/kernfs.h>
#include <linux/file.h>
#include <linux/vmalloc.h>
#include <linux/uaccess.h>
#include <linux/elf.h>
#include <linux/kallsyms.h>
#include <linux/version.h>
#include <linux/list.h>
#include <linux/spinlock.h>
#include <linux/rcupdate.h>
#include <asm/elf.h>
#include <linux/mm.h>
#include <linux/string.h>
#include <asm/cacheflush.h>
#include <linux/module.h>
#include <linux/set_memory.h>
#include <linux/export.h>
#include <linux/slab.h>
#include <asm/insn.h>
#include <linux/kprobes.h>
#include <linux/stacktrace.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0) && defined(CONFIG_MODULES)
#include <linux/moduleloader.h>
#endif
#include "kpm.h"
#include "compact.h"
#include "../kernel_compat.h"

#define KPM_NAME_LEN 32
#define KPM_ARGS_LEN 1024
#define KPM_PATH_LEN 256
#define KPM_BUFFER_LEN 256
#define KPM_LIST_BUFFER_LEN 1024

#ifndef NO_OPTIMIZE
#if defined(__GNUC__) && !defined(__clang__)
#define NO_OPTIMIZE __attribute__((optimize("O0")))
#elif defined(__clang__)
#define NO_OPTIMIZE __attribute__((optnone))
#else
#define NO_OPTIMIZE
#endif
#endif

// Helper macro to ensure stable hook point by adding NOP at function entry
// This helps avoid issues with PAC instructions that compiler may add
#define HOOK_SAFE_ENTRY() __asm__ volatile("nop" ::: "memory")

// ============================================================================
// Stub Functions - These are hook points for KernelPatch
// ============================================================================

noinline NO_OPTIMIZE void sukisu_kpm_load_module_path(const char *path,
						      const char *args,
						      void *ptr, int *result)
{
	HOOK_SAFE_ENTRY();
	pr_info("kpm: Stub function called (sukisu_kpm_load_module_path). "
		"path=%s args=%s ptr=%p\n",
		path, args, ptr);
	__asm__ volatile("nop");
}
EXPORT_SYMBOL(sukisu_kpm_load_module_path);

noinline NO_OPTIMIZE void sukisu_kpm_unload_module(const char *name, void *ptr,
						   int *result)
{
	HOOK_SAFE_ENTRY();
	pr_info("kpm: Stub function called (sukisu_kpm_unload_module). "
		"name=%s ptr=%p\n",
		name, ptr);
	__asm__ volatile("nop");
}
EXPORT_SYMBOL(sukisu_kpm_unload_module);

noinline NO_OPTIMIZE void sukisu_kpm_num(int *result)
{
	HOOK_SAFE_ENTRY();
	pr_info("kpm: Stub function called (sukisu_kpm_num).\n");
	__asm__ volatile("nop");
}
EXPORT_SYMBOL(sukisu_kpm_num);

noinline NO_OPTIMIZE void sukisu_kpm_info(const char *name, char *buf,
					  int bufferSize, int *size)
{
	HOOK_SAFE_ENTRY();
	pr_info("kpm: Stub function called (sukisu_kpm_info). "
		"name=%s buffer=%p\n",
		name, buf);
	__asm__ volatile("nop");
}
EXPORT_SYMBOL(sukisu_kpm_info);

noinline NO_OPTIMIZE void sukisu_kpm_list(void *out, int bufferSize,
					  int *result)
{
	HOOK_SAFE_ENTRY();
	pr_info("kpm: Stub function called (sukisu_kpm_list). "
		"buffer=%p size=%d\n",
		out, bufferSize);
}
EXPORT_SYMBOL(sukisu_kpm_list);

noinline NO_OPTIMIZE void sukisu_kpm_control(const char *name, const char *args,
					     long arg_len, int *result)
{
	HOOK_SAFE_ENTRY();
	pr_info("kpm: Stub function called (sukisu_kpm_control). "
		"name=%p args=%p arg_len=%ld\n",
		name, args, arg_len);
	__asm__ volatile("nop");
}
EXPORT_SYMBOL(sukisu_kpm_control);

noinline NO_OPTIMIZE void sukisu_kpm_version(char *buf, int bufferSize)
{
	HOOK_SAFE_ENTRY();
	pr_info("kpm: Stub function called (sukisu_kpm_version). "
		"buffer=%p\n",
		buf);
}
EXPORT_SYMBOL(sukisu_kpm_version);

/**
 * Copy string from user space with validation
 * @param dst: destination buffer
 * @param src: source user space pointer
 * @param size: buffer size
 * @return: length copied on success, negative error code on failure
 */
static long copy_string_from_user(char *dst, const char __user *src, size_t size)
{
	if (!src || !dst || size == 0)
		return -EINVAL;

	if (!ksu_access_ok(src, size))
		return -EFAULT;

	long len = strncpy_from_user(dst, src, size);
	return (len < 0) ? len : len;
}

/**
 * Copy result to user space
 * @param result_code: user space pointer to store result
 * @param result: result value to copy
 * @return: 0 on success, negative error code on failure
 */
static int copy_result_to_user(unsigned long result_code, int result)
{
	if (!result_code)
		return -EINVAL;

	if (!ksu_access_ok(result_code, sizeof(int)))
		return -EFAULT;

	if (copy_to_user(result_code, &result, sizeof(result)) != 0) {
		pr_info("kpm: Copy result to user failed.\n");
		return -EFAULT;
	}

	return 0;
}

// Handle KPM_LOAD command
static int handle_kpm_load(unsigned long arg1, unsigned long arg2, int *result)
{
	char kernel_load_path[KPM_PATH_LEN] = { 0 };
	char kernel_args_buffer[KPM_PATH_LEN] = { 0 };

	if (!arg1) {
		*result = -EINVAL;
		return 0;
	}

	long path_len = copy_string_from_user(kernel_load_path,
					      (const char __user *)arg1,
					      sizeof(kernel_load_path));
	if (path_len < 0) {
		*result = path_len;
		return 0;
	}

	if (arg2 != 0) {
		long args_len = copy_string_from_user(kernel_args_buffer,
						      (const char __user *)arg2,
						      sizeof(kernel_args_buffer));
		if (args_len < 0) {
			*result = args_len;
			return 0;
		}
	}

	sukisu_kpm_load_module_path(kernel_load_path, kernel_args_buffer,
				    NULL, result);
	return 0;
}

// Handle KPM_UNLOAD command
static int handle_kpm_unload(unsigned long arg1, int *result)
{
	char kernel_name_buffer[KPM_PATH_LEN] = { 0 };

	if (!arg1) {
		*result = -EINVAL;
		return 0;
	}

	long name_len = copy_string_from_user(kernel_name_buffer,
					      (const char __user *)arg1,
					      sizeof(kernel_name_buffer));
	if (name_len < 0) {
		*result = name_len;
		return 0;
	}

	sukisu_kpm_unload_module(kernel_name_buffer, NULL, result);
	return 0;
}

// Handle KPM_NUM command
static int handle_kpm_num(int *result)
{
	sukisu_kpm_num(result);
	return 0;
}

// Handle KPM_INFO command
static int handle_kpm_info(unsigned long arg1, unsigned long arg2, int *result)
{
	char kernel_name_buffer[KPM_BUFFER_LEN] = { 0 };
	char buf[KPM_BUFFER_LEN] = { 0 };
	int size;

	if (!arg1 || !arg2) {
		*result = -EINVAL;
		return 0;
	}

	long name_len = copy_string_from_user(kernel_name_buffer,
					      (const char __user *)arg1,
					      sizeof(kernel_name_buffer));
	if (name_len < 0) {
		*result = name_len;
		return 0;
	}

	sukisu_kpm_info(kernel_name_buffer, buf, sizeof(buf), &size);

	if (!ksu_access_ok(arg2, size)) {
		*result = -EFAULT;
		return 0;
	}

	*result = copy_to_user(arg2, buf, size);
	return 0;
}

// Handle KPM_LIST command
static int handle_kpm_list(unsigned long arg1, unsigned long arg2, int *result)
{
	char buf[KPM_LIST_BUFFER_LEN] = { 0 };
	int len = (int)arg2;

	if (len <= 0) {
		*result = -EINVAL;
		return 0;
	}

	if (!ksu_access_ok(arg2, len)) {
		*result = -EFAULT;
		return 0;
	}

	sukisu_kpm_list(buf, sizeof(buf), result);

	if (*result > len) {
		*result = -ENOBUFS;
		return 0;
	}

	if (copy_to_user(arg1, buf, len) != 0) {
		pr_info("kpm: Copy list to user failed.\n");
		*result = -EFAULT;
		return 0;
	}

	return 0;
}

// Handle KPM_CONTROL command
static int handle_kpm_control(unsigned long arg1, unsigned long arg2, int *result)
{
	char kpm_name[KPM_NAME_LEN] = { 0 };
	char kpm_args[KPM_ARGS_LEN] = { 0 };

	if (!arg1 || !arg2) {
		*result = -EINVAL;
		return 0;
	}

	long name_len = copy_string_from_user(kpm_name,
					      (const char __user *)arg1,
					      sizeof(kpm_name));
	if (name_len <= 0) {
		*result = -EINVAL;
		return 0;
	}

	long arg_len = copy_string_from_user(kpm_args,
					     (const char __user *)arg2,
					     sizeof(kpm_args));

	sukisu_kpm_control(kpm_name, kpm_args, arg_len, result);
	return 0;
}

// Handle KPM_VERSION command
static int handle_kpm_version(unsigned long arg1, unsigned long arg2, int *result)
{
	char buffer[KPM_BUFFER_LEN] = { 0 };

	sukisu_kpm_version(buffer, sizeof(buffer));

	unsigned int outlen = (unsigned int)arg2;
	int len = strlen(buffer);
	if (len >= outlen)
		len = outlen - 1;

	*result = copy_to_user(arg1, buffer, len + 1);
	return 0;
}

/**
 * Main handler for KPM commands
 * Routes control codes to appropriate handlers
 */
noinline int sukisu_handle_kpm(unsigned long control_code, unsigned long arg1,
			       unsigned long arg2, unsigned long result_code)
{
	int res = -1;

	switch (control_code) {
	case SUKISU_KPM_LOAD:
		handle_kpm_load(arg1, arg2, &res);
		break;

	case SUKISU_KPM_UNLOAD:
		handle_kpm_unload(arg1, &res);
		break;

	case SUKISU_KPM_NUM:
		handle_kpm_num(&res);
		break;

	case SUKISU_KPM_INFO:
		handle_kpm_info(arg1, arg2, &res);
		break;

	case SUKISU_KPM_LIST:
		handle_kpm_list(arg1, arg2, &res);
		break;

	case SUKISU_KPM_CONTROL:
		handle_kpm_control(arg1, arg2, &res);
		break;

	case SUKISU_KPM_VERSION:
		handle_kpm_version(arg1, arg2, &res);
		break;

	default:
		pr_err("kpm: unknown control code: %lu\n", control_code);
		res = -EINVAL;
		break;
	}

	copy_result_to_user(result_code, res);
	return 0;
}
EXPORT_SYMBOL(sukisu_handle_kpm);

// Check if control code is a valid KPM control code
int sukisu_is_kpm_control_code(unsigned long control_code)
{
	return (control_code >= CMD_KPM_CONTROL &&
		control_code <= CMD_KPM_CONTROL_MAX) ? 1 : 0;
}
EXPORT_SYMBOL(sukisu_is_kpm_control_code);

// IOCTL handler for KPM commands
int do_kpm(void __user *arg)
{
	struct ksu_kpm_cmd cmd;

	if (copy_from_user(&cmd, arg, sizeof(cmd))) {
		pr_err("kpm: copy_from_user failed\n");
		return -EFAULT;
	}

	if (!ksu_access_ok(cmd.control_code, sizeof(int))) {
		pr_err("kpm: invalid control_code pointer %px\n",
		       (void *)cmd.control_code);
		return -EFAULT;
	}

	if (!ksu_access_ok(cmd.result_code, sizeof(int))) {
		pr_err("kpm: invalid result_code pointer %px\n",
		       (void *)cmd.result_code);
		return -EFAULT;
	}

	return sukisu_handle_kpm(cmd.control_code, cmd.arg1, cmd.arg2,
				 cmd.result_code);
}
