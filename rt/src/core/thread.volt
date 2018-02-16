// Copyright © 2016-2017, Jakob Bornecrantz.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
/*!
 * Code to support spawning new threads.
 *
 * The runtime has to be aware of new threads in order
 * to make GC work, so all new threads should be
 * spawned through this interface.
 */
module core.thread;
version (!Metal):

import core.rt.gc: vrt_gc_init, allocDg, vrt_gc_get_alloc_dg, vrt_gc_shutdown;
import vrt.os.thread : __stack_bottom;

version (Windows) {
	import core.c.windows;
} else {
	import core.c.pthread;
	import core.c.posix.unistd;
}

struct Thread
{
public:
	/*!
	 * Start this thread.
	 *
	 * Invokes `func` in a new thread. Calling any `start`
	 * function more than once will cause an error to be
	 * generated.
	 */
	fn start(func: fn())
	{
		version (Windows) {
			mHandle = CreateThread(null, 0, ThreadProc, cast(void*)func, 0, &mThreadId);
		} else {
			pthread_create(&mHandle, null, ThreadProc, cast(void*)func);
		}
	}

	/*!
	 * Wait for this thread to complete.
	 */
	fn join()
	{
		version (Windows) {
			WaitForSingleObject(mHandle, INFINITE);
			mHandle = null;
		} else {
			pthread_join(mHandle, null);
		}
	}

	/*!
	 * Is this thread running?
	 */
	@property fn isRunning() bool
	{
		version (Windows) {
			return mHandle !is null;
		} else {
			return false;
		}
	}

private:
	version (Windows) {
		mThreadId: DWORD;
		mHandle: HANDLE;
	} else {
		mHandle: pthread_t;
	}

public:
global:
	/*!
	 * Cause the calling thread to sleep for `ms` milliseconds.
	 */
	fn sleep(ms: u32)
	{
		version (Windows) {
			Sleep(ms);
		} else {
			usleep(ms * 1000);
		}
	}
}

private:

version (Windows) extern (Windows) fn ThreadProc(ptr: LPVOID) DWORD
{
	__stack_bottom = cast(void*)&ptr;
	vrt_gc_init();
	allocDg = vrt_gc_get_alloc_dg();

	dgt := (cast(fn())ptr);
	dgt();
	vrt_gc_shutdown();
	return 0;
}
else extern (C) fn ThreadProc(ptr: void*) void*
{
	__stack_bottom = cast(void*)&ptr;
	vrt_gc_init();
	allocDg = vrt_gc_get_alloc_dg();

	dgt := (cast(fn())ptr);
	dgt();
	vrt_gc_shutdown();
	return null;
}
