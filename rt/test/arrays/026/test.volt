//T macro:expect-failure
// Invalid array allocation.
module test;

fn main() i32
{
	a: i32[];
	// array concatenation, only arrays allowed.
	b: i32[] = new i32[](a, 3);

	return 0;
}
