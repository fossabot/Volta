// Copyright © 2015, Bernard Helyer.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volt.semantic.storageremoval;

import ir = volt.ir.ir;
import volt.ir.util;

import volt.errors;
import volt.semantic.typer : realType;
import volt.visitor.visitor : StringBuffer;
import volt.visitor.prettyprinter : PrettyPrinter;


/**
 * Turn all storage types associated with type into flags.
 * There should be no way to get a storage type from the
 * resulting type.
 *
 * Attaches the glossedName to types, too.
 *
 * This modifies the original type, so copy if you want to
 * retain the original.
 *
 * If type is null, null is returned.
 */
ir.Type flattenStorage(ir.Type type, ir.CallableType ct=null, size_t ctIndex=0)
{
	if (type is null) {
		return null;
	}

/+
	XXX Disabled for now, this was really really really slow.
	if (type.glossedName == "") {
		StringBuffer sb;
		auto pp = new PrettyPrinter(" ", &sb.sink);
		pp.transform(type);
		type.glossedName = sb.str;
		pp.close();
	}
+/

	switch (type.nodeType) with (ir.NodeType) {
	case StorageType:
		auto stype = cast(ir.StorageType) type;
		auto base = stype.base;
		if (base !is null) {
			flattenOneStorage(stype, base, ct, ctIndex);
			return flattenStorage(base);
		} else {
			return stype;
		}
	case ArrayType:
		auto atype = cast(ir.ArrayType) type;
		atype.base = flattenStorage(atype.base);
		return atype;
	case PointerType:
		auto ptype = cast(ir.PointerType) type;
		ptype.base = flattenStorage(ptype.base);
		auto current = ptype;
		while (current !is null) {
			addStorage(current.base, current);
			current = cast(ir.PointerType)current.base;
		}
		return ptype;
	case FunctionType:
	case DelegateType:
		auto ftype = cast(ir.CallableType) type;
		ftype.ret = flattenStorage(ftype.ret);
		foreach (i; 0 .. ftype.params.length) {
			ftype.params[i] = flattenStorage(ftype.params[i], ftype, i);
		}
		return ftype;
	default:
		return type;
	}
}

/**
 * Turn stype into a flag, and attach it to type.
 */
void flattenOneStorage(ir.StorageType stype, ir.Type type,
                       ir.CallableType ct = null, size_t ctIndex = size_t.max)
{
	final switch (stype.type) with (ir.StorageType.Kind) {
	case Const: type.isConst = true; break;
	case Immutable: type.isImmutable = true; break;
	case Scope: type.isScope = true; break;
	case Ref:
	case Out:
		if (ct is null) {
			throw panic(stype.location, "ref attached to non parameter");
		}
		if (stype.type == Ref) {
			ct.isArgRef[ctIndex] = true;
		} else {
			ct.isArgOut[ctIndex] = true;
		}
		break;
	case Auto: break;
	}
}
