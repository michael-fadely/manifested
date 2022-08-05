import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.stdio;
import std.string;
import std.traits;

import manifested;

// TODO: output progress

struct Documentation
{
	string[] lines;

	this(string[] inputLines ...)
	{
		lines = inputLines;
	}
}

// TODO: Operation.clean - remove unversioned files (which includes ignore file implementation)
/// Manifest operations to perform.
enum Operation
{
	@Documentation("Invalid mode.")
	none,

	@Documentation("Generate a manifest for a given target directory.")
	generate,

	@Documentation("Verify file integrity of a directory according to its manifest.")
	verify,

	@Documentation("Compare two manifested directories.")
	compare,

	@Documentation("Update target directory to match source directory's manifest.")
	update,

	@Documentation("Combination of `verify` and `update`.",
	               "First performs `update` to pull changed files, then `verify`",
	               "to validate data. If any files fail the validation check,",
	               "`update` is run again to pull the latest files.")
	repair,

	@Documentation("Copies manifest and tracked files from the source to the target.")
	deploy
}

size_t getLongestName()
{
	size_t result = 0;

	static foreach (member; EnumMembers!Operation)
	{
		static if (member !is Operation.none)
		{
			result = max(result, to!string(member).length);
		}
	}

	return result;
}

void printOperationDocs()
{
	enum longestName = getLongestName();
	enum multiLinePadding = replicate(" ", longestName + ": ".length);

	static foreach (member; EnumMembers!Operation)
	{
		static if (member !is Operation.none)
		{
			{
				enum string memberName = to!string(member);
				enum string memberHeader = format!("%*s: ")(longestName, memberName);
				stdout.write("\t", memberHeader);

				enum docUDAs = getUDAs!(mixin(member), Documentation);

				static if (!docUDAs.length || docUDAs[0].lines.empty)
				{
					stdout.writeln("n/a");
				}
				else
				{
					enum doc = docUDAs[0];

					stdout.writeln(doc.lines[0]);

					static if (doc.lines.length > 1)
					{
						foreach (string line; doc.lines[1 .. $])
						{
							stdout.writeln("\t", multiLinePadding, line);
						}
					}
				}
			}
		}
	}
}

int main(string[] args)
{
	Operation mode;
	string sourcePath;
	string targetPath;

	try
	{
		auto result = getopt(args,
		                     std.getopt.config.required,
		                     "m|mode",
		                     "Operation to perform.",
		                     &mode,

		                     "s|source",
		                     "Source directory for the operation.",
		                     &sourcePath,

		                     "t|target",
		                     "Target directory of the operation.",
		                     &targetPath);

		if (result.helpWanted)
		{
			auto formattedOptions = appender!string;
			defaultGetoptFormatter(formattedOptions, "Manifest generator.", result.options, "\t%*s %*s%*s%s\n");

			stdout.writeln(formattedOptions.data);

			stdout.writeln("Operation modes:");
			printOperationDocs();
			return 0;
		}
	}
	catch (Exception ex)
	{
		stderr.writeln(ex.msg);
		return -1;
	}

	try
	{
		// handle pre-conditions first
		final switch (mode) with (Operation)
		{
			case none:
				enforce(mode != none, "Invalid operation mode specified.");
				break;

			case generate:
			case verify:
				enforce(!targetPath.empty, "Target directory must be specified for operation mode " ~ to!string(mode));
				break;

			case compare:
			case update:
			case repair:
			case deploy:
				enforce(!sourcePath.empty && !targetPath.empty,
				        "Source and target directories must both be specified for operation mode " ~ to!string(mode));
				break;
		}

		final switch (mode) with (Operation)
		{
			case none:
				assert(false);

			case generate:
				generateManifest(targetPath);
				break;

			case verify:
				verifyManifest(targetPath);
				break;

			case compare:
				compareManifests(sourcePath, targetPath);
				break;

			case update:
				applyManifest(sourcePath, targetPath);
				break;

			case repair:
				repairManifest(sourcePath, targetPath);
				break;

			case deploy:
				deployManifest(sourcePath, targetPath);
				break;
		}
	}
	catch (Exception ex)
	{
		stderr.writeln(ex.msg);
		return -1;
	}

	debug
	{
		stderr.writeln();
		stderr.writeln("press enter to exit");
		stdin.readln();
	}

	return 0;
}

private:

const manifestFileName = ".manifest";

void generateManifest(string sourcePath)
{
	auto generator = new ManifestGenerator();
	ManifestEntry[] manifest = generator.generate(sourcePath);
	Manifest.toFile(manifest, buildNormalizedPath(sourcePath, manifestFileName));
}

void printDiff(ManifestDiff[] diff)
{
	size_t n;

	foreach (ManifestDiff entry; diff.filter!(x => x.state != ManifestState.unchanged))
	{
		++n;
		final switch (entry.state)
		{
			// impossible, but `final switch`
			case ManifestState.unchanged:
				assert(false, `Encountered entry state "`
				              ~ to!string(entry.state)
				              ~ `", which should be impossible in this function.`);

			case ManifestState.added:
			case ManifestState.changed:
				stderr.writeln(entry.state, `: "`, entry.current.filePath, `"`);
				break;

			case ManifestState.removed:
				stderr.writeln(entry.state, `: "`, entry.last.filePath, `"`);
				break;

			case ManifestState.moved:
				stderr.writeln(entry.state, `: "`, entry.last.filePath, `" -> "`, entry.current.filePath, `"`);
				break;
		}
	}

	if (!n)
	{
		stderr.writeln("integrity OK");
	}
}

void verifyManifest(string sourcePath)
{
	auto generator = new ManifestGenerator();
	ManifestEntry[] manifest = Manifest.fromFile(buildNormalizedPath(sourcePath, manifestFileName));
	ManifestDiff[] diff = generator.verify(sourcePath, manifest);

	printDiff(diff);
}

void compareManifests(string sourcePath, string targetPath)
{
	ManifestEntry[] sourceManifest = Manifest.fromFile(buildNormalizedPath(sourcePath, manifestFileName));
	ManifestEntry[] targetManifest = Manifest.fromFile(buildNormalizedPath(targetPath, manifestFileName));

	auto generator = new ManifestGenerator();
	ManifestDiff[] diff = generator.diff(sourceManifest, targetManifest);

	printDiff(diff);
}

void applyManifest(string sourcePath, ManifestEntry[] sourceManifest, string targetPath, ManifestEntry[] targetManifest)
{
	auto generator = new ManifestGenerator();
	ManifestDiff[] diff = generator.diff(sourceManifest, targetManifest);

	stderr.writeln("diff:");
	printDiff(diff);
	stderr.writeln();

	foreach (ManifestDiff entry; diff.filter!(x => x.state != ManifestState.unchanged))
	{
		final switch (entry.state)
		{
			// impossible, but `final switch`
			case ManifestState.unchanged:
				assert(false, `Encountered entry state "`
				              ~ to!string(entry.state)
				              ~ `", which should be impossible in this function.`);

			case ManifestState.added:
			case ManifestState.changed:
			{
				stderr.writeln("applying: ", entry.state, `: "`, entry.current.filePath, `"`);

				const sourceFile = buildNormalizedPath(sourcePath, entry.current.filePath);
				const targetFile = buildNormalizedPath(targetPath, entry.current.filePath);

				const targetDir = dirName(targetFile);

				if (!exists(targetDir))
				{
					mkdirRecurse(targetDir);
				}

				copy(sourceFile, targetFile);
				break;
			}

			case ManifestState.removed:
			{
				stderr.writeln("applying: ", entry.state, `: "`, entry.last.filePath, `"`);

				const toRemove = buildNormalizedPath(targetPath, entry.last.filePath);

				if (exists(toRemove))
				{
					remove(toRemove);
				}

				break;
			}

			case ManifestState.moved:
			{
				stderr.writeln("applying: ", entry.state, `: "`, entry.last.filePath, `" -> "`, entry.current.filePath, `"`);

				const from = buildNormalizedPath(targetPath, entry.last.filePath);
				const to   = buildNormalizedPath(targetPath, entry.current.filePath);

				if (!exists(from))
				{
					stderr.writeln("missing! Treating as new!");
					goto case ManifestState.added;
				}

				const toDir = dirName(to);

				if (!exists(toDir))
				{
					mkdirRecurse(toDir);
				}

				rename(from, to);
				break;
			}
		}
	}

	// remove all directories unique to the old manifest
	string[] oldDirs = Manifest.getOldDirectories(targetManifest, sourceManifest);

	foreach (dir; oldDirs.map!(s => buildNormalizedPath(targetPath, s))
	                     .filter!(s => exists(s)))
	{
		size_t dirEntryCount;
		DirIterator entries = dirEntries(dir, SpanMode.shallow);

		// count entries in the directory, ignoring exceptions (hence manual iteration)
		while (!entries.empty)
		{
			try
			{
				const entry = entries.front;
			}
			catch (Exception ex)
			{
				// ok well I mean it's not empty then, and we can only assume it
				// "exists", even if it's e.g. a broken symlink
			}

			++dirEntryCount;
			entries.popFront();
		}

		// the folder doesn't have any files in it, so just remove it.
		if (!dirEntryCount)
		{
			rmdir(dir);
		}
	}

	// when all is said and done, copy the manifest from the source to the target
	copy(sourcePath.buildNormalizedPath(manifestFileName), targetPath.buildNormalizedPath(manifestFileName));
}

void applyManifest(string sourcePath, string targetPath)
{
	string sourceManifestPath = buildNormalizedPath(sourcePath, manifestFileName);
	string targetManifestPath = buildNormalizedPath(targetPath, manifestFileName);

	enforce(exists(sourceManifestPath), "Source directory is missing its manifest!");
	enforce(exists(targetManifestPath), "Target directory is missing its manifest!");

	ManifestEntry[] sourceManifest = Manifest.fromFile(sourceManifestPath);
	ManifestEntry[] targetManifest = Manifest.fromFile(targetManifestPath);

	applyManifest(sourcePath, sourceManifest, targetPath, targetManifest);
}

void repairManifest(string sourcePath, string targetPath)
{
	auto generator = new ManifestGenerator();

	ManifestEntry[] sourceManifest = Manifest.fromFile(sourcePath.buildNormalizedPath(manifestFileName));

	string targetManifestPath = targetPath.buildNormalizedPath(manifestFileName);

	// if a target manifest already exists...
	if (exists(targetManifestPath))
	{
		// first, read the existing manifest and perform a normal update
		ManifestEntry[] targetManifest = Manifest.fromFile(targetManifestPath);
		applyManifest(sourcePath, sourceManifest, targetPath, targetManifest);

		stderr.writeln();
		stderr.writeln("verifying...");
		stderr.writeln();

		// now verify against the source manifest which whill match the target manifest
		ManifestDiff[] diff = generator.verify(targetPath, sourceManifest);
		applyManifest(sourcePath, sourceManifest, targetPath, Manifest.fromDiff(diff));

		return;
	}

	ManifestDiff[] diff = generator.verify(targetPath, sourceManifest);

	printDiff(diff);

	if (diff.all!(x => x.state == ManifestState.unchanged))
	{
		return;
	}

	stderr.writeln();
	stderr.writeln("repairing...");
	stderr.writeln();

	ManifestEntry[] fakeManifest = Manifest.fromDiff(diff);

	applyManifest(sourcePath, sourceManifest, targetPath, fakeManifest);
}

void deployManifest(string sourcePath, string targetPath)
{
	string sourceManifestPath = buildNormalizedPath(sourcePath, manifestFileName);

	enforce(exists(sourceManifestPath), "Source directory is missing its manifest!");

	if (!exists(targetPath))
	{
		mkdirRecurse(targetPath);
	}

	ManifestEntry[] sourceManifest = Manifest.fromFile(sourceManifestPath);
	applyManifest(sourcePath, sourceManifest, targetPath, null);
}
