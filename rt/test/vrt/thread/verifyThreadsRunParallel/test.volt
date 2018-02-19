module main;

import core.thread;

global counter: u64;

fn main() i32
{
	thread1, thread2: Thread;
	thread1.start(threadOne);
	while (counter != 0) {
	}
	return 0;
}

fn threadOne()
{
	while (true) {
		counter++;
	}
}
