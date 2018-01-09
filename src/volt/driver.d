/*#D*/
// Copyright © 2012-2016, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volt.driver;

import core.exception;

import io = watt.io.std : output, error;

import watt.path : temporaryFilename, dirSeparator;
import watt.process : spawnProcess, wait;
import watt.io.file : remove, exists, read, isFile;
import watt.io.streams : OutputFileStream;
import watt.conv : toLower;
import watt.text.diff : diff;
import watt.text.sink : StringSink;
import watt.text.format : format;
import watt.text.string : split, endsWith, replace, indexOf;

import volt.util.path;
import volt.util.perf : Accumulator, Perf, perf;
import volt.util.cmdgroup;
import volt.exceptions;
import volt.interfaces;
import volt.errors;
import volt.arg;
import volta.settings;
import volta.ir.location;
import ir = volta.ir;

import volta.parser.parser;
import volt.semantic.languagepass;
import volt.llvm.driver;
import volt.llvm.backend;
import volt.lowerer.image;
import volt.util.mangledecoder;

import volta.visitor.visitor;
import volt.visitor.prettyprinter;
import volt.visitor.debugprinter;
import volt.visitor.jsonprinter;

import volta.postparse.missing;


/*!
 * Default implementation of @link volt.interfaces.Driver Driver@endlink, replace
 * this if you wish to change the basic operation of the compiler.
 */
class VoltDriver : Driver, ErrorSink
{
public:
	VersionSet ver;
	TargetInfo target;
	Frontend frontend;
	LanguagePass languagePass;
	Backend backend;
	TempfileManager tempMan;

	Pass[] debugVisitors;

protected:
	Arch mArch;
	Platform mPlatform;

	bool mNoLink;
	bool mNoBackend;
	bool mRemoveConditionalsOnly;
	bool mMissingDeps;
	bool mEmitLLVM;

	bool mArWithLLLVM;  // llvm-ar

	string mOutput;

	string mDepFile;
	string[] mDepFiles; //!< All files used as input to this compiled.

	string[] mIncludes;
	string[] mSrcIncludes;
	string[] mSourceFiles;
	string[] mImportAsSrc;
	string[] mBitcodeFiles;
	string[] mObjectFiles;

	string[] mStringImportPaths;

	bool mInternalDiff;
	bool mInternalDebug;
	bool mInternalNoCatch;

	ir.Module[] mCommandLineModules;

	//! Used to track if we should debug print on error.
	bool mDebugPassesRun;

	Accumulator mAccumReading;
	Accumulator mAccumParsing;

	// For the modules generated by CTFE.
	BackendHostResult[ir.NodeID] mCompiledModules;

	//! If not null, use this to print json files.
	JsonPrinter mJsonPrinter;

	//! Driver for the LLVM part of Volta.
	LLVMDriver mLLVMDriver;
	//! Settings for the llvm backend driver.
	LLVMDriverSettings mLLVMSettings;

	//! Decide on the different parts of the driver to use.
	bool mRunVoltend;
	bool mRunBackend;


public:
	this(Settings s, VersionSet ver, TargetInfo target, string[] files)
	in {
		assert(s !is null);
		assert(ver !is null);
		assert(target !is null);
	}
	body {
		this.ver = ver;
		this.target = target;
		this.execDir = s.execDir;
		this.identStr = s.identStr;
		this.internalDebug = s.internalDebug;
		this.tempMan = new TempfileManager();
		this.mLLVMSettings = new LLVMDriverSettings();

		// Timers
		mAccumReading = new Accumulator("p1-reading");
		mAccumParsing = new Accumulator("p1-parsing");

		setTargetInfo(target, s.arch, s.platform, s.cRuntime);
		setVersionSet(ver, s.arch, s.platform, s.cRuntime);

		decideStuff(s);
		decideJson(s);
		decideLinker(s);
		decideOutputFile(s);
		decideCheckErrors();

		addFiles(files);
		auto mode = decideMode(s);
		this.frontend = new Parser(s, this);
		this.languagePass = new VoltLanguagePass(this, this, ver, target,
			s, frontend, mode, s.warningsEnabled);

		decideParts();
		decideBackend();

		debugVisitors ~= new DebugMarker("Running DebugPrinter:");
		debugVisitors ~= new DebugPrinter();
		debugVisitors ~= new DebugMarker("Running PrettyPrinter:");
		debugVisitors ~= new PrettyPrinter();
	}


	/*
	 *
	 * ErrorSink functions
	 *
	 */

	override void onWarning(string msg, string file, int line)
	{
		io.error.writefln("warning: %s", msg);
	}

	override void onWarning(ref in ir.Location loc, string msg, string file = __FILE__, int line = __LINE__)
	{
		io.error.writefln("%s: warning: %s", loc.toString(), msg);
	}

	override void onError(string msg, string file, int line)
	{
		throw new CompilerError(msg, file, line);
	}

	override void onError(ref in ir.Location loc, string msg, string file = __FILE__, int line = __LINE__)
	{
		throw new CompilerError(/*#ref*/ loc, msg, file, line);
	}

	override void onPanic(string msg, string file, int line)
	{
		throw new CompilerPanic(msg, file, line);
	}

	override void onPanic(ref in ir.Location loc, string msg, string file = __FILE__, int line = __LINE__)
	{
		throw new CompilerPanic(/*#ref*/ loc, msg, file, line);
	}


	/*
	 *
	 * Driver functions.
	 *
	 */

	/*!
	 * Retrieve a Module by its name. Returns null if none is found.
	 */
	override ir.Module loadModule(ir.QualifiedName name)
	{
		auto srcPath = pathFromQualifiedName(name, mSrcIncludes, ".volt");
		auto incPath = pathFromQualifiedName(name, mIncludes, ".volt");
		if (srcPath is null && incPath is null) {
			srcPath = pathFromQualifiedName(name, mSrcIncludes, ".d");
			incPath = pathFromQualifiedName(name, mIncludes, ".d");
		}

		if (srcPath !is null) {
			mSourceFiles ~= srcPath;
			auto m = loadAndParse(srcPath);
			languagePass.addModule(m);
			mCommandLineModules ~= m;
			return m;
		}
		if (incPath is null) {
			return null;
		}
		return loadAndParse(incPath);
	}

	override string stringImport(ref in Location loc, string fname)
	{
		if (mStringImportPaths.length == 0) {
			throw makeNoStringImportPaths(/*#ref*/loc);
		}

		if (fname.indexOf("..") >= 0) {
			throw makeError(/*#ref*/loc, "string import path with '..'.");
		}

		foreach (path; mStringImportPaths) {
			auto filename = format("%s%s%s", path, dirSeparator, fname);
			// We need both exists and isFile here because phobos
			// will throw from isFile if the file doesn't exists.
			if (!exists(filename) || !isFile(filename)) {
				continue;
			}

			mDepFiles ~= filename;
			return cast(string)read(filename);
		}

		throw makeImportFileOpenFailure(/*#ref*/loc, fname);
	}

	override ir.Module[] getCommandLineModules()
	{
		return mCommandLineModules;
	}

	override void close()
	{
		foreach (m; mCompiledModules.values) {
			m.close();
		}

		frontend.close();
		languagePass.close();
		if (backend !is null) {
			backend.close();
		}

		frontend = null;
		languagePass = null;
		backend = null;
	}


	/*
	 *
	 * Misc functions.
	 *
	 */

	void addFile(string file)
	{
		version (Windows) {
			// VOLT TEST.VOLT  REM Reppin' MS-DOS
			file = toLower(file);
		}

		if (!exists(file)) {
			auto str = format("could not open file '%s'", file);
			throw new CompilerError(str);
		}

		if (endsWith(file, ".d", ".volt") > 0) {
			mSourceFiles ~= file;
		} else if (endsWith(file, ".bc")) {
			mBitcodeFiles ~= file;
		} else if (endsWith(file, ".o", ".obj")) {
			mObjectFiles ~= file;
		} else if (endsWith(file, ".lib")) {
			mLLVMSettings.libFiles ~= file;
		} else if (endsWith(file, ".a")) {
			mLLVMSettings.libFiles ~= file;
		} else {
			auto str = format("unknown file type '%s'", file);
			throw new CompilerError(str);
		}
	}

	void addFiles(string[] files)
	{
		foreach (file; files) {
			addFile(file);
		}
	}

	int compile()
	{
		int ret = 2;
		mDebugPassesRun = false;
		scope (success) {
			debugPasses();

			tempMan.removeTempfiles();

			if (ret == 0) {
				writeDepFile();
			}

			perf.mark(Perf.Mark.EXIT);
		}

		if (mInternalNoCatch) {
			ret = intCompile();
			return ret;
		}

		try {
			ret = intCompile();
			return ret;
		} catch (CompilerPanic e) {
			io.output.flush();
			io.error.writefln(e.msg);
			auto loc = e.allocationLocation;
			if (loc != "") {
				io.error.writefln("%s", loc);
			}
			io.error.flush();
			return 2;
		} catch (CompilerError e) {
			io.output.flush();
			io.error.writefln(e.msg);
			auto loc = e.allocationLocation;
			debug if (loc != "") {
				io.error.writefln("%s", loc);
			}
			io.error.flush();
			return 1;
		} catch (Throwable t) {
			io.output.flush();
			io.error.writefln("panic: %s", t.msg);
			version (Volt) auto loc = t.location;
			else auto loc = t.file is null ? "" : format("%s:%s", t.file, t.line);
			if (loc != "") {
				io.error.writefln("%s", loc);
			}
			io.error.flush();
			return 2;
		}
	}

	override BackendHostResult hostCompile(ir.Module mod)
	{
		// We cache the result of the module compile here.
		auto p = mod.uniqueId in mCompiledModules;
		if (p !is null) {
			return *p;
		}

		// Need to run phase3 on it first.
		languagePass.phase3([mod]);

		// Then jit compile it so we can run it in our process.
		auto d = languagePass.driver;
		auto compMod = backend.compileHost(mod, languagePass.ehPersonalityFunc,
		languagePass.llvmTypeidFor, d.execDir, d.identStr);
		mCompiledModules[mod.uniqueId] = compMod;
		return compMod;
	}


protected:
	void writeDepFile()
	{
		if (mDepFile is null ||
		    mDepFiles is null) {
			return;
		}

		assert(mOutput !is null);

		// We have to be careful that this is a UNIX file.
		auto d = new OutputFileStream(mDepFile);
		d.writef("%s: \\\n", replace(mOutput, `\`, `/`));
		foreach (dep; mDepFiles[0 .. $-1]) {
			d.writef("\t%s \\\n", replace(dep, `\`, `/`));
		}
		d.writefln("\t%s\n", replace(mDepFiles[$-1], `\`, `/`));
		d.flush();
		d.close();
	}

	string pathFromQualifiedName(ir.QualifiedName name, string[] includes,
	                             string suffix)
	{
		string[] validPaths;
		foreach (path; includes) {
			auto paths = genPossibleFilenames(
				path, name.strings, suffix);

			foreach (possiblePath; paths) {
				if (exists(possiblePath)) {
					validPaths ~= possiblePath;
				}
			}
		}

		if (validPaths is null) {
			return null;
		}
		if (validPaths.length > 1) {
			throw makeMultipleValidModules(name, validPaths);
		}
		return validPaths[0];
	}

	/*!
	 * Loads a file and parses it.
	 */
	ir.Module loadAndParse(string file)
	{
		// Add file to dependencies for this compile.
		mDepFiles ~= file;

		string src;
		{
			mAccumReading.start();
			scope (exit) mAccumReading.stop();
			src = cast(string) read(file);
		}

		mAccumParsing.start();
		scope (exit) mAccumParsing.stop();
		return frontend.parseNewFile(src, file);
	}

	int intCompile()
	{
		if (mRunVoltend) {
			int ret = intCompileVoltend();
			if (ret != 0) {
				return ret;
			}
		}
		if (mRunBackend) {
			return intCompileBackend();
		}
		return 0;
	}

	int intCompileVoltend()
	{
		// Start parsing.
		perf.mark(Perf.Mark.PARSING);

		// Load all modules to be compiled.
		// Don't run phase 1 on them yet.
		foreach (file; mSourceFiles) {
			debugPrint("Parsing %s.", file);

			auto m = loadAndParse(file);
			languagePass.addModule(m);
			mCommandLineModules ~= m;
		}

		foreach (imp; mImportAsSrc) {
			auto q = new ir.QualifiedName();
			foreach (id; split(imp, '.')) {
				q.identifiers ~= new ir.Identifier(id);
			}
			auto m = loadModule(q);
			bool hasAdded;
			foreach_reverse (other; mCommandLineModules) {
				if (other is m) {
					hasAdded = true;
					break;
				}
			}
			if (!hasAdded) {
				languagePass.addModule(m);
				mCommandLineModules ~= m;
			}
		}

		// Skip setting up the pointers incase object
		// was not loaded, after that we are done.
		if (mRemoveConditionalsOnly) {
			languagePass.phase1(mCommandLineModules);
			return 0;
		}



		// Setup diff buffers.
		auto ppstrs = new string[](mCommandLineModules.length);
		auto dpstrs = new string[](mCommandLineModules.length);

		preDiff(mCommandLineModules, "Phase 1", ppstrs, dpstrs);
		perf.mark(Perf.Mark.PHASE1);

		// Force phase 1 to be executed on the modules.
		// This might load new modules.
		auto lp = cast(VoltLanguagePass)languagePass;
		lp.phase1(mCommandLineModules);
		bool hasPhase1 = true;
		while (hasPhase1) {
			hasPhase1 = false;
			auto mods = lp.getModules();
			foreach (m; mods) {
				hasPhase1 = !m.hasPhase1 || hasPhase1;
				lp.phase1(m);
			}
		}
		postDiff(mCommandLineModules, ppstrs, dpstrs);


		// Are we only looking for missing deps?
		if (mMissingDeps) {
			foreach (m; lp.postParseImpl.missing.getMissing()) {
				io.output.writefln("%s", m);
			}
			io.output.flush();
			return 0;
		}


		// After we have loaded all of the modules
		// setup the pointers, this allows for suppling
		// a user defined object module.
		lp.setupOneTruePointers();


		// New modules have been loaded,
		// make sure to run everthing on them.
		auto allMods = languagePass.getModules();


		// All modules need to be run through phase2.
		preDiff(mCommandLineModules, "Phase 2", ppstrs, dpstrs);
		perf.mark(Perf.Mark.PHASE2);
		languagePass.phase2(allMods);
		postDiff(mCommandLineModules, ppstrs, dpstrs);


		// Printout json file.
		if (mJsonPrinter !is null) {
			mJsonPrinter.transform(target, mCommandLineModules);
		}


		// All modules need to be run through phase3.
		preDiff(mCommandLineModules, "Phase 3", ppstrs, dpstrs);
		perf.mark(Perf.Mark.PHASE3);
		languagePass.phase3(allMods);
		postDiff(mCommandLineModules, ppstrs, dpstrs);


		// For the debug printing here if no exception has been thrown.
		debugPasses();
		return 0;
	}

	int intCompileBackend()
	{
		// We do this here because we know that bitcode files are
		// being used. Add files to dependencies for this compile.
		foreach (file; mBitcodeFiles) {
			mDepFiles ~= file;
		}

		if (mEmitLLVM) {
			return mLLVMDriver.makeBitcode(mOutput,
				mCommandLineModules, mBitcodeFiles);
		} else if (mNoLink) {
			return mLLVMDriver.makeObject(mOutput,
				mCommandLineModules, mBitcodeFiles);
		}

		// We do this here because we know that object files are
		// being used. Add files to dependencies for this compile.
		foreach (file; mObjectFiles) {
			mDepFiles ~= file;
		}

		if (mArWithLLLVM) {
			return mLLVMDriver.makeArchive(mOutput,
				mCommandLineModules, mBitcodeFiles, mObjectFiles);
		} else {
			return mLLVMDriver.doNativeLink(mOutput,
				mCommandLineModules, mBitcodeFiles, mObjectFiles);
		}
	}


	/*
	 *
	 * Decision methods.
	 *
	 */

	static Mode decideMode(Settings settings)
	{
		if (settings.removeConditionalsOnly) {
			return Mode.RemoveConditionalsOnly;
		} else if (settings.missingDeps) {
			return Mode.MissingDeps;
		} else {
			return Mode.Normal;
		}
	}

	void decideStuff(Settings settings)
	{
		mArch = settings.arch;
		mPlatform = settings.platform;

		mNoLink = settings.noLink;
		mNoBackend = settings.noBackend;
		mMissingDeps = settings.missingDeps;
		mEmitLLVM = settings.emitLLVM;
		mRemoveConditionalsOnly = settings.removeConditionalsOnly;

		mInternalDiff = settings.internalDiff;
		mInternalDebug = settings.internalDebug;
		mInternalNoCatch = settings.noCatch;

		mDepFile = settings.depFile;

		mIncludes = settings.includePaths;
		mSrcIncludes = settings.srcIncludePaths;
		mImportAsSrc = settings.importAsSrc;

		mLLVMSettings.libraryPaths = settings.libraryPaths;
		mLLVMSettings.libraryFlags = settings.libraryFiles;

		mLLVMSettings.frameworkNames = settings.frameworkNames;
		mLLVMSettings.frameworkPaths = settings.frameworkPaths;

		mStringImportPaths = settings.stringImportPaths;
	}

	void decideJson(Settings settings)
	{
		if (settings.jsonOutput !is null) {
			mJsonPrinter = new JsonPrinter(settings.jsonOutput);
		}
	}

	void decideLinker(Settings settings)
	{
		mLLVMSettings.xLD = settings.xld;
		mLLVMSettings.xCC = settings.xcc;
		mLLVMSettings.xLink = settings.xlink;
		mLLVMSettings.xClang = settings.xclang;
		mLLVMSettings.xLinker = settings.xlinker;

		// Clang has a special place.
		mLLVMSettings.ar = settings.llvmAr;
		mLLVMSettings.clang = settings.clang;

		if (settings.llvmAr !is null) {
			mArWithLLLVM = true;
		} else if (settings.linker !is null) {
			switch (mPlatform) with (Platform) {
			case MSVC:
				mLLVMSettings.linker = settings.linker;
				mLLVMSettings.linkWithLink = true;
				break;
			default:
				throw new CompilerError("Use --cc or --clang instead of --linker");
			}
		} else if (settings.clang !is null) {
			mLLVMSettings.linker = settings.clang;
			mLLVMSettings.linkWithCC = true;
			// We pretend clang is cc.
			mLLVMSettings.xCC ~= settings.xclang;
		} else if (settings.ld !is null) {
			throw new CompilerError("Use --cc or --clang instead of --ld");
		} else if (settings.cc !is null) {
			mLLVMSettings.linker = settings.cc;
			mLLVMSettings.linkWithCC = true;
		} else if (settings.link !is null) {
			mLLVMSettings.linker = settings.link;
			mLLVMSettings.linkWithLink = true;
		} else {
			switch (mPlatform) with (Platform) {
			case MSVC:
				mLLVMSettings.linker = "link.exe";
				mLLVMSettings.linkWithLink = true;
				break;
			default:
				mLLVMSettings.linker = "clang";
				mLLVMSettings.linkWithCC = true;
				break;
			}
		}
	}

	void decideOutputFile(Settings settings)
	{
		bool outputBinary = !mNoLink && !mArWithLLLVM && !mEmitLLVM;
		bool outputExe = mLLVMSettings.linkWithLink && outputBinary;

		// Setup the output file
		if (settings.outputFile !is null) {
			mOutput = settings.outputFile;
			if (outputExe && !mOutput.endsWith("exe")) {
				mOutput = format("%s.exe", mOutput);
			}
		} else if (mArWithLLLVM) {
			mOutput = DEFAULT_A;
		} else if (mEmitLLVM) {
			mOutput = DEFAULT_BC;
		} else if (mNoLink) {
			mOutput = DEFAULT_OBJ;
		} else {
			assert(outputBinary);
			mOutput = DEFAULT_EXE;
		}
	}

	void decideCheckErrors()
	{
		if (mLLVMSettings.libFiles.length > 0 && !mLLVMSettings.linkWithLink) {
			throw new CompilerError(format("can not link '%s'",
				mLLVMSettings.libFiles[0]));
		}

		if (mEmitLLVM && !mNoLink) {
			throw makeEmitLLVMNoLink();
		}
	}

	void decideParts()
	{
		mRunVoltend = mSourceFiles.length > 0 || mImportAsSrc.length > 0;

		mRunBackend =
			!mNoBackend &&
			!mMissingDeps &&
			!mRemoveConditionalsOnly;
	}

	void decideBackend()
	{
		if (mRunBackend) {
			assert(languagePass !is null);
			backend = new LlvmBackend(languagePass, languagePass.driver.internalDebug);
			mLLVMDriver = new LLVMDriver(this, tempMan, target,
				languagePass, backend, mLLVMSettings);
		}
	}


private:
	/*
	 *
	 * Debug printing helpers.
	 *
	 */

	/*!
	 * If we are debugging print messages.
	 */
	void debugPrint(string msg, string s)
	{
		if (mInternalDebug) {
			io.output.writefln(msg, s);
		}
	}

	void debugPasses()
	{
		if (mInternalDebug && !mDebugPassesRun) {
			mDebugPassesRun = true;
			foreach (pass; debugVisitors) {
				foreach (mod; mCommandLineModules) {
					pass.transform(mod);
				}
			}
		}
	}

	void preDiff(ir.Module[] mods, string title, string[] ppstrs, string[] dpstrs)
	{
		if (!mInternalDiff) {
			return;
		}

		assert(mods.length == ppstrs.length && mods.length == dpstrs.length);
		StringSink ppBuf, dpBuf;
		version (Volt) {
			auto diffPP = new PrettyPrinter(" ", ppBuf.sink);
			auto diffDP = new DebugPrinter(" ", dpBuf.sink);
		} else {
			auto diffPP = new PrettyPrinter(" ", ppBuf.sink);
			auto diffDP = new DebugPrinter(" ", dpBuf.sink);
		}
		foreach (i, m; mods) {
			ppBuf.reset();
			dpBuf.reset();
			io.output.writefln("Transformations performed by %s:", title);
			diffPP.transform(m);
			diffDP.transform(m);
			ppstrs[i] = ppBuf.toString();
			dpstrs[i] = dpBuf.toString();
		}
		diffPP.close();
		diffDP.close();
	}

	void postDiff(ir.Module[] mods, string[] ppstrs, string[] dpstrs)
	{
		if (!mInternalDiff) {
			return;
		}
		assert(mods.length == ppstrs.length && mods.length == dpstrs.length);
		StringSink sb;
		version (Volt) {
			auto pp = new PrettyPrinter(" ", sb.sink);
			auto dp = new DebugPrinter(" ", sb.sink);
		} else {
			auto pp = new PrettyPrinter(" ", &sb.sink);
			auto dp = new DebugPrinter(" ", &sb.sink);
		}
		foreach (i, m; mods) {
			sb.reset();
			dp.transform(m);
			diff(dpstrs[i], sb.toString());
			sb.reset();
			pp.transform(m);
			diff(ppstrs[i], sb.toString());
		}
		pp.close();
		dp.close();
	}
}

TargetInfo setTargetInfo(TargetInfo target, Arch arch, Platform platform, CRuntime cRuntime)
{
	target.arch = arch;
	target.platform = platform;
	target.cRuntime = cRuntime;

	final switch (platform) with (Platform) {
	case MSVC, Metal:
		target.haveEH = false;
		break;
	case MinGW, Linux, OSX:
		target.haveEH = true;
		break;
	}

	final switch (arch) with (Arch) {
	case X86:
		target.isP64 = false;
		target.ptrSize = 4;
		target.alignment.int1 = 1;
		target.alignment.int8 = 1;
		target.alignment.int16 = 2;
		target.alignment.int32 = 4;
		target.alignment.int64 = 4; // abi 4, prefered 8
		target.alignment.float32 = 4;
		target.alignment.float64 = 4; // abi 4, prefered 8
		target.alignment.ptr = 4;
		target.alignment.aggregate = 8; // abi X, prefered 8
		break;
	case X86_64:
		target.isP64 = true;
		target.ptrSize = 8;
		target.alignment.int1 = 1;
		target.alignment.int8 = 1;
		target.alignment.int16 = 2;
		target.alignment.int32 = 4;
		target.alignment.int64 = 8;
		target.alignment.float32 = 4;
		target.alignment.float64 = 8;
		target.alignment.ptr = 8;
		target.alignment.aggregate = 8; // abi X, prefered 8
		break;
	}

	return target;
}

void setVersionSet(VersionSet ver, Arch arch, Platform platform, CRuntime cRuntime)
{
	final switch (cRuntime) with (CRuntime) {
	case None:
		ver.overwriteVersionIdentifier("CRuntime_None");
		break;
	case MinGW:
		ver.overwriteVersionIdentifier("CRuntime_All");
		break;
	case Glibc:
		ver.overwriteVersionIdentifier("CRuntime_All");
		ver.overwriteVersionIdentifier("CRuntime_Glibc");
		break;
	case Darwin:
		ver.overwriteVersionIdentifier("CRuntime_All");
		break;
	case Microsoft:
		ver.overwriteVersionIdentifier("CRuntime_All");
		ver.overwriteVersionIdentifier("CRuntime_Microsoft");
		break;
	}
	final switch (platform) with (Platform) {
	case MinGW:
		ver.overwriteVersionIdentifier("Windows");
		ver.overwriteVersionIdentifier("MinGW");
		break;
	case MSVC:
		ver.overwriteVersionIdentifier("Windows");
		ver.overwriteVersionIdentifier("MSVC");
		break;
	case Linux:
		ver.overwriteVersionIdentifier("Linux");
		ver.overwriteVersionIdentifier("Posix");
		break;
	case OSX:
		ver.overwriteVersionIdentifier("OSX");
		ver.overwriteVersionIdentifier("Posix");
		break;
	case Metal:
		ver.overwriteVersionIdentifier("Metal");
		break;
	}
	final switch (arch) with (Arch) {
	case X86:
		ver.overwriteVersionIdentifier("X86");
		ver.overwriteVersionIdentifier("LittleEndian");
		ver.overwriteVersionIdentifier("V_P32");
		break;
	case X86_64:
		ver.overwriteVersionIdentifier("X86_64");
		ver.overwriteVersionIdentifier("LittleEndian");
		ver.overwriteVersionIdentifier("V_P64");
		break;
	}
}

version (Windows) {
	enum DEFAULT_A = "a.a";
	enum DEFAULT_BC = "a.bc";
	enum DEFAULT_OBJ = "a.obj";
	enum DEFAULT_EXE = "a.exe";
} else {
	enum DEFAULT_A = "a.a";
	enum DEFAULT_BC = "a.bc";
	enum DEFAULT_OBJ = "a.obj";
	enum DEFAULT_EXE = "a.out";
}
