module test;

import vrt.gc.slab;
import vrt.ext.stdc;


fn main() i32
{
	/* The slab is in charge of zeroing memory on free,
	 * so we need to give our test Slab real memory to
	 * manage.
	 */
	order := sizeToOrder(512);
	size := orderToSize(order) * Slab.MaxSlots;
	memory := calloc(1, size);
	if (memory is null) {
		return 5;
	}

	block: Slab;
	block.setup(order, memory, false, false, false);

	// Allocate 511 blocks, check that one is left.
	foreach (0 .. 511) {
		block.allocate();
	}
	if (block.freeSlots != 1) {
		return 1;
	}

	// Allocate the last one
	block.allocate();
	if (block.freeSlots != 0) {
		return 2;
	}

	// Make sure that bit 5 is not free
	if (block.isFree(5) != false) {
		return 3;
	}

	// Free bit 5 and check that it becomes free
	block.free(5);
	if (block.isFree(5) != true) {
		return 4;
	}

	free(memory);

	return 0;
}

