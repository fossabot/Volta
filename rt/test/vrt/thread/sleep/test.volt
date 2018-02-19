module main;

import core.thread;
import vrt.os.monotonic;

fn main() i32
{
	a := vrt_monotonic_ticks();
	Thread.sleep(100);
	b := vrt_monotonic_ticks();
	d := b - a;
	if (d < (vrt_monotonic_ticks_per_second() / 10)) {
		return 1;
	} else {
		return 0;
	}
}

