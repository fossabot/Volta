//T default:no
//T retval:1
//T run:volta -o %t %s
// Test that assigning null to AAs is an error.
module test;

fn main() i32
{
	result: i32 = 42;
	aa := [3:result];
	aa := null;
	return aa[3];
}
