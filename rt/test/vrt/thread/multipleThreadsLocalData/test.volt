module main;

import core.thread;

local counter: i32;
global results: i32[3];

fn main() i32
{
	thread1, thread2: Thread;
	thread1.start(threadOne);
	thread2.start(threadTwo);
	thread1.join();
	thread2.join();
	results[0] = counter;
	if (results[0] != 0) {
		return 1;
	}
	if (results[1] != 1) {
		return 2;
	}
	if (results[2] != 2) {
		return 3;
	}
	return 0;
}

fn threadOne()
{
	counter = 1;
	results[1] = counter;
}

fn threadTwo()
{
	counter = 2;
	results[2] = counter;
}
