module test;

fn three(out a: i32)
{
	a = 3;
}

fn callfptr(fp: fn!Volt(out i32), out i: i32)
{
	fp(out i);
}

fn main() i32
{
	fp: fn!Volt(out a : i32) = three;
	i: i32;
	callfptr(fp, out i);
	return i - 3;
}
