/*#D*/
// Copyright © 2017, Jakob Bornecrantz.  All rights reserved.
// Copyright © 2017, Bernard Helyer.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volt.semantic.templatelifter;

import watt.text.format;

import ir = volta.ir;
import ircopy = volta.util.copy;
import volta.util.util;
import volta.util.dup;

import volt.errors;
import volt.interfaces;

import volt.ir.lifter;

import volta.visitor.visitor;

import volta.postparse.gatherer : Gatherer;
import volta.postparse.attribremoval : AttribRemoval, applyAttribute;
import volta.postparse.scopereplacer : ScopeReplacer;

import volt.semantic.lookup;
import volt.semantic.extyper;
import volt.semantic.classify;
import volt.semantic.typer;
import volt.semantic.mangle;


class TemplateLifter : Lifter
{
public:
	string currentTemplateDefinitionName;
	ir.Type currentInstanceType;

public:
	override ir.TopLevelBlock lift(ir.TopLevelBlock old)
	{
		auto tlb = new ir.TopLevelBlock(old);
		foreach (ref n; tlb.nodes) {
			switch (n.nodeType) with (ir.NodeType) {
			case Function:
				auto func = cast(ir.Function)n;
				n = lift(func);
				break;
			case Variable:
				auto var = cast(ir.Variable)n;
				n = lift(var);
				break;
			case Struct:
				auto s = cast(ir.Struct)n;
				n = lift(s);
				break;
			case Union:
				auto u = cast(ir.Union)n;
				n = lift(u);
				break;
			case Interface:
				auto _i = cast(ir._Interface)n;
				n = lift(_i);
				break;
			case Class:
				auto c = cast(ir.Class)n;
				n = lift(c);
				break;
			case Import:
				auto i = cast(ir.Import)n;
				n = lift(i);
				break;
			case Enum:
				auto e = cast(ir.Enum)n;
				n = lift(e);
				break;
			case EnumDeclaration:
				auto e = cast(ir.EnumDeclaration)n;
				n = lift(null, e);
				break;
			case AssertStatement:
				n = copyStatement(null, cast(ir.AssertStatement)n);
				break;
			case Alias:
				auto a = cast(ir.Alias)n;
				n = lift(a);
				break;
			default:
				throw panic(n, "not implemented!");
			}
		}
		return tlb;
	}

	override ir.Function lift(ir.Function old)
	{
		auto f = new ir.Function(old);
		liftInPlace(old, /*#ref*/f);
		return f;
	}

	void liftInPlace(ir.Function old, ref ir.Function f)
	{
		// These should never be set.
		if (old.myScope !is null) { throw panic("invalid templated function"); }
		if (old.thisHiddenParameter !is null) { throw panic("invalid templated function"); }
		if (old.nestedHiddenParameter !is null) { throw panic("invalid templated function"); }
		if (old.nestedVariable !is null) { throw panic("invalid templated function"); }
		if (old.nestStruct !is null) { throw panic("invalid templated function"); }
		if (old.nestedFunctions !is null) { throw panic("invalid templated function"); }

		// Copy params.
		foreach (ref p; f.params) {
			p = lift(p);
			p.func = f;
		}

		foreach (ref sf; f.scopeSuccesses) {
			sf = lift(sf);
		}

		foreach (ref sf; f.scopeExits) {
			sf = lift(sf);
		}

		foreach (ref sf; f.scopeFailures) {
			sf = lift(sf);
		}

		f.type = copy(old.type);
		if (old.hasInContract) {
			if (f.parsedIn !is null) {
				f.parsedIn = copy(null, old.parsedIn);
			} else {
				f.tokensIn = f.tokensIn.dup();
			}
		}
		if (old.hasOutContract) {
			if (f.parsedOut !is null) {
				f.parsedOut = copy(null, old.parsedOut);
			} else {
				f.tokensOut = f.tokensOut.dup();
			}
		}
		if (old.hasBody) {
			if (f.parsedBody !is null) {
				f.parsedBody = copy(null, old.parsedBody);
			} else {
				f.tokensBody = f.tokensBody.dup();
			}
		}
	}

	override ir.FunctionParam lift(ir.FunctionParam old)
	{
		auto p = new ir.FunctionParam(old);
		if (old.assign !is null) {
			p.assign = copyExp(old.assign);
		}
		return p;
	}

	override ir.Variable lift(ir.Variable n)
	{
		auto v = new ir.Variable(n);
		v.type = copyType(n.type);
		if (n.assign !is null) {
			v.assign = copyExp(n.assign);
		}
		return v;
	}

	ir.Import lift(ir.Import old)
	{
		auto n = new ir.Import(old);
		n.targetModules = new ir.Module[](old.targetModules.length);
		for (size_t i = 0; i < n.targetModules.length; ++i) {
			n.targetModules[i] = lift(old.targetModules[i]);
		}
		return n;
	}

	ir.Module lift(ir.Module old)
	{
		auto n = new ir.Module(old);
		n.children = lift(old.children);
		return n;
	}

	ir.Aggregate lift(ir.Aggregate old)
	{
		switch (old.nodeType) with (ir.NodeType) {
		case Class: return lift(cast(ir.Class)old);
		case Interface: return lift(cast(ir._Interface)old);
		case Struct: return lift(cast(ir.Struct)old);
		case Union: return lift(cast(ir.Union)old);
		default:
			throw panic(old, "not implemented!");
		}
	}

	override ir.Enum lift(ir.Enum old)
	{
		auto n = new ir.Enum(old);
		foreach (i, ref edecl; n.members) {
			edecl = lift(n, old.members[i]);
		}
		if (old.base !is null) {
			n.base = copyType(old.base);
		}
		return n;
	}

	ir.EnumDeclaration lift(ir.Enum en, ir.EnumDeclaration old)
	{
		auto n = new ir.EnumDeclaration(old);
		if (en !is null) {
			n.type = buildTypeReference(/*#ref*/en.loc, en, en.name);
		} else {
			n.type = copyType(old.type);
		}
		if (old.assign !is null) {
			n.assign = copyExp(old.assign);
		}
		if (old.prevEnum !is null) {
			n.prevEnum = lift(en, old.prevEnum);
		}
		return n;
	}

	override ir.Alias lift(ir.Alias old)
	{
		auto a = new ir.Alias(old);
		if (old.id !is null) {
			a.id = copyQualifiedName(old.id);
		}
		if (old.type !is null) {
			a.type = copyType(old.type);
		}
		if (old.staticIf !is null) {
			a.staticIf = copyAliasStaticIf(old.staticIf);
		}
		return a;
	}

	override ir.Struct lift(ir.Struct old)
	{
		auto s = new ir.Struct(old);
		foreach (i, ref anonagg; s.anonymousAggregates) {
			anonagg = lift(old.anonymousAggregates[i]);
		}
		foreach (i, ref anonvar; s.anonymousVars) {
			anonvar = lift(old.anonymousVars[i]);
		}
		s.members = lift(old.members);
		foreach (i, ref ctor; s.constructors) {
			ctor = lift(old.constructors[i]);
		}
		return s;
	}

	override ir.Union lift(ir.Union old)
	{
		auto s = new ir.Union(old);
		foreach (i, ref anonagg; s.anonymousAggregates) {
			anonagg = lift(old.anonymousAggregates[i]);
		}
		foreach (i, ref anonvar; s.anonymousVars) {
			anonvar = lift(old.anonymousVars[i]);
		}
		s.members = lift(old.members);
		foreach (i, ref ctor; s.constructors) {
			ctor = lift(old.constructors[i]);
		}
		return s;
	}

	override ir.Class lift(ir.Class old)
	{
		// These should never be set.
		if (old.myScope !is null) { throw panic("invalid templated class"); }
		if (old.parentClass !is null) { throw panic("invalid templated class"); }
		if (old.layoutStruct !is null) { throw panic("invalid templated class"); }
		if (old.parentInterfaces.length > 0) { throw panic("invalid templated class"); }
		if (old.interfaceOffsets.length > 0) { throw panic("invalid templated class"); }
		if (old.anonymousAggregates.length > 0) { throw panic("invalid templated class"); }
		if (old.anonymousVars.length > 0) { throw panic("invalid templated class"); }

		auto c = new ir.Class(old);
		foreach (i, ref ctor; c.userConstructors) {
			ctor = lift(old.userConstructors[i]);
		}
		if (old.vtableVariable !is null) {
			c.vtableVariable = lift(old.vtableVariable);
		}
		if (old.classinfoVariable !is null) {
			c.classinfoVariable = lift(old.classinfoVariable);
		}
		foreach (i, ref var; c.ifaceVariables) {
			var = lift(old.ifaceVariables[i]);
		}
		if (old.initVariable !is null) {
			c.initVariable = lift(old.initVariable);
		}
		c.members = lift(old.members);
		return c;
	}

	override ir._Interface lift(ir._Interface old)
	{
		if (old.myScope !is null) { throw panic("invalid templated class"); }
		if (old.layoutStruct !is null) { throw panic("invalid templated class"); }
		if (old.parentInterfaces.length > 0) { throw panic("invalid templated class"); }
		if (old.anonymousAggregates.length > 0) { throw panic("invalid templated class"); }
		if (old.anonymousVars.length > 0) { throw panic("invalid templated class"); }

		auto _i = new ir._Interface(old);
		foreach (i, ref iface; _i.parentInterfaces) {
			iface = lift(old.parentInterfaces[i]);
		}
		if (old.layoutStruct !is null) {
			_i.layoutStruct = lift(old.layoutStruct);
		}
		foreach (i, ref anonagg; _i.anonymousAggregates) {
			anonagg = lift(old.anonymousAggregates[i]);
		}
		foreach (i, ref anonvar; _i.anonymousVars) {
			anonvar = lift(old.anonymousVars[i]);
		}
		_i.members = lift(old.members);
		return _i;
	}

	override ir.Node liftedOrPanic(ir.Node node, string msg) { throw panic(node, msg); }

	override ir.BlockStatement copy(ir.Scope parent, ir.BlockStatement old)
	{
		assert(old !is null);
		assert(old.myScope is null);
		assert(parent is null);

		auto n = new ir.BlockStatement(old);

		foreach (ref stat; n.statements) {
			stat = copyStatement(n.myScope, stat);
		}

		return n;
	}

	// Volt can't do the "alias copy = super.copy" trick as D.
	override ir.FunctionType copy(ir.FunctionType old) { return super.copy(old); }

	override ir.TypeReference copy(ir.TypeReference old)
	{
		auto tr = super.copy(old);
		if (tr.id.identifiers.length == 1 &&
			tr.id.identifiers[0].value == currentTemplateDefinitionName) {
			tr.type = currentInstanceType;
		}
		return tr;
	}


public:
	void templateLift(ref ir.Function func, LanguagePass lp, ir.TemplateInstance ti)
	{
		auto current = func.myScope;
		auto td = getTemplateDefinition(current, lp, ti);
		auto deffunc = td._function;
		panicAssert(func, deffunc !is null);

		currentTemplateDefinitionName = td.name;

		auto processed = processTemplateArguments(lp, func.myScope.parent, func.myScope, td, ti);

		func.copy(/*old*/deffunc, /*liftingTemplate*/true);
		liftInPlace(deffunc, /*#ref*/func);

		/* The attributes couldn't be applied with the other functions,
		 * as it didn't have a type at that point. Hide the templateInstance
		 * and apply them now.
		 */
		func.templateInstance = null;
		foreach (delayedAttribute; func.delayedAttributes) {
			applyAttribute(func, delayedAttribute, lp.errSink, lp.target);
		}
		func.templateInstance = ti;

		auto mod = getModuleFromScope(/*#ref*/func.loc, current);
		auto gatherer = new Gatherer(/*warnings*/false, lp.errSink);

		foreach (var; func.params) {
			if (var.name !is null) {
				ir.Status status;
				func.myScope.addValue(var, var.name, /*#out*/status);
				if (status != ir.Status.Success) {
					throw panic(/*#ref*/func.loc, "value redefinition");
				}
			}
		}
		if (func.myScope.parent.node.nodeType != ir.NodeType.Module) {
			throw makeError(/*#ref*/func.loc, "non top level template function");
		}
		func.kind = ir.Function.Kind.Function;
		void addNode(ir.Node n) { func.templateAdditions ~= n; }
		version (D_Version2) auto _dg = &addNode;
		else auto _dg = addNode;
		addArgumentsToInstanceEnvironment(lp, processed, func.myScope, td, ti, _dg);
	}

	void templateLift(ref ir.Struct s, LanguagePass lp, ir.TemplateInstance ti)
	{
		auto current = s.myScope;
		auto td = getTemplateDefinition(current, lp, ti);
		auto defstruct = td._struct;
		panicAssert(s, defstruct !is null);

		currentTemplateDefinitionName = td.name;
		currentInstanceType = s;

		// Make sure we look in the scope where the template inst. is.
		auto processed = processTemplateArguments(lp, s.myScope.parent, s.myScope, td, ti);

		// Do the lifting of the children.
		s.members = lift(defstruct.members);

		// Setup any passes that needs to process the copied nodes.
		auto mod = getModuleFromScope(/*#ref*/s.loc, current);
		auto gatherer = new Gatherer(/*warnings*/false, lp.errSink);

		// Run the gatherer.
		gatherer.push(s.myScope);
		accept(s, gatherer);
		void addNode(ir.Node n) { s.members.nodes ~= n; }
		version (D_Version2) auto _dg = &addNode;
		else auto _dg = addNode;
		addArgumentsToInstanceEnvironment(lp, processed, s.myScope, td, ti, _dg);
	}

private:
	bool isTemplateInstance(ir.Type t)
	{
		auto _struct = cast(ir.Struct)realType(t);
		return _struct !is null && _struct.templateInstance !is null;
	}

	void addArgumentsToInstanceEnvironment(LanguagePass lp, ir.Node[] processed, ir.Scope instanceScope,
	ir.TemplateDefinition td, ir.TemplateInstance ti, NodeAdder addNode)
	{
		foreach (param; td.parameters) {
			ti.names ~= param.name;
		}
		foreach (i, ref arg; ti.arguments) {
			auto name = td.parameters[i].name;
			instanceScope.remove(name);
			if (auto a = cast(ir.Alias)processed[i]) {
				// Add the alias to the scope and set its store.
				ir.Status status;
				a.store = instanceScope.addAlias(a, a.name, /*#out*/status);
				if (status != ir.Status.Success) {
					throw panic(/*#ref*/a.loc, "alias redefines symbol");
				}
				addNode(a);

				// Do the lookup here.
				lp.resolveAlias(a);

				// Make sure that the alias we got is a type.
				assert(a.store.myAlias !is null);
				if (cast(ir.Type)a.store.myAlias.node is null) {
					throw makeExpected(arg, "type");
				}
			} else if (auto type = cast(ir.Type)processed[i]) {
				ir.Status status;
				instanceScope.addType(type, name, /*#out*/status);
				if (status != ir.Status.Success) {
					throw panic(/*#ref*/type.loc, "template type addition redefinition");
				}
			} else if (auto exp = cast(ir.Exp)processed[i]) {
				auto type = copyType(td.parameters[i].type);
				auto ed = buildEnumDeclaration(/*#ref*/ti.loc, type, exp, name);
				ir.Status status;
				instanceScope.addEnumDeclaration(ed, /*#out*/status);
				if (status != ir.Status.Success) {
					throw panic(/*#ref*/ti.loc, "enum declaration redefinition");
				}
				addNode(ed);
			} else {
				throw makeExpected(/*#ref*/arg.loc, "expression or type");
			}
		}
	}
}
import watt.io.std;
private:

alias NodeAdder = void delegate(ir.Node);

ir.TemplateDefinition getTemplateDefinition(ir.Scope current, LanguagePass lp, ir.TemplateInstance ti)
{
	if (!ti.explicitMixin) {
		throw makeExpected(/*#ref*/ti.loc, "explicit mixin");
	}
	auto store = lookup(lp, current, ti.name);
	if (store is null) {
		throw makeFailedLookup(/*#ref*/ti.loc, ti.name.toString());
	}
	auto td = cast(ir.TemplateDefinition)store.node;
	if (td is null) {
		throw makeError(/*#ref*/ti.loc, format("'%s' is not a template definition", ti.name.toString()));
	}
	if (ti.arguments.length != td.parameters.length) {
		throw makeExpected(ti, format("%s argument%s", td.parameters.length,
			td.parameters.length == 1 ? "" : "s"));
	}
	return td;
}

/*
 * Given the definintion and instance, return a new list with
 * resolved types of template instance arguments.
 * (The expressions will be untouched, but in the
 * new list also)
 *
 * The output list will be the same length as the instance's
 * argument list, and will be in the same order.
 */
ir.Node[] processTemplateArguments(LanguagePass lp, ir.Scope lookScope, ir.Scope newScope, ir.TemplateDefinition td, ir.TemplateInstance ti)
{
	auto processed = new ir.Node[](ti.arguments.length);
	// Loop over all arguments.
	foreach (i, ref arg; ti.arguments) {

		if (td.parameters[i].type !is null) {

			// This is a expression.
			processed[i] = arg;

		} else if (auto type = cast(ir.Type)arg) {

			// A simple type like 'u32' or 'typeof(Foo)'
			resolveType(lp, lookScope, /*#ref*/type);
			processed[i] = type;

		} else {

			// A qname like 'pkg.mod.Struct'
			auto exp = cast(ir.Exp)arg;
			if (exp is null) {
				throw makeExpected(arg, "type");
			}

			// In order to properly set the store up as a
			// alias to types we need to resolve the alias
			// like normal aliases via the lp.
			auto a = new ir.Alias();
			a.isResolved = true;
			a.name = td.parameters[i].name;
			a.lookScope = lookScope;
			a.access = ir.Access.Public;
			a.id = exptoQualifiedName(exp);

			// We don't do any lookup/resolving here
			// because we need a.store to be a proper store
			// that will still around.
			processed[i] = a;
		}

		// All arguments reserve a name.
		auto reservedStore = newScope.reserveId(td, td.parameters[i].name);
		if (reservedStore is null) {
			throw panic(/*#ref*/td.loc, "couldn't reserve identifier");
		}
	}
	return processed;
}

/*
 * Given a Type that's been smuggled in as an expression (it'll either be an
 * IdentifierExp or a QualifiedName as a Postfix chain), return a QualifiedName,
 * or throw an error.
 *
 * The template parser can't tell if it needs to parse an expression or a type,
 * so for user defined types it has to parse them as an expression. By the time
 * we see them, we know they're types, so the postfix will be unprocessed, and
 * we can do things like this.
 */
ir.QualifiedName exptoQualifiedName(ir.Exp exp, ir.QualifiedName qname = null)
{
	if (qname is null) {
		qname = new ir.QualifiedName();
		qname.loc = exp.loc;
	}
	if (exp.nodeType == ir.NodeType.IdentifierExp) {
		auto iexp = exp.toIdentifierExpFast();
		auto ident = new ir.Identifier(iexp.value);
		ident.loc = iexp.loc;
		qname.identifiers ~= ident;
	} else if (exp.nodeType == ir.NodeType.Postfix) {
		auto postfix = exp.toPostfixFast();
		if (postfix.identifier is null) {
			throw makeExpected(exp, "type");
		}
		exptoQualifiedName(postfix.child, qname);
		qname.identifiers ~= postfix.identifier;
	} else {
		throw makeExpected(exp, "type");
	}
	return qname;
}
