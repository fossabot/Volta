//T compiles:yes
//T retval:42
// Can't call functions from member functions.
module test;


void func()
{

}

class Test
{
	this()
	{
		return;
	}

	void myFunc()
	{
		// Thinks func is a member on Test.
		func();
	}
}

int main()
{
	return 42;
}