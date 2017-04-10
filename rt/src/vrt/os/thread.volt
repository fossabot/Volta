// Copyright © 2016-2017, Bernard Helyer.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module vrt.os.thread;

import vrt.gc.util;

/**
 * The bottom of the stack.
 *
 * Initialised by vrt_gc_find_stack_bottom function, called in the
 * main function generated by the compiler.
 */
global __stack_bottom: void*;

fn vrt_get_stack_bottom() void*
{
	gcAssert(__stack_bottom !is null);
	return __stack_bottom;
}
