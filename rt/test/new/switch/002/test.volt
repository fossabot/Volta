//T default:no
//T macro:expect-failure
module test;

fn main() i32
{
	switch (2) {
	case 1:
		return 1;
	case 2:
		return 5;
	case 3:
		return 7;
	}
}
