import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.stdio;
import std.string;

import manifested;

// TODO: clean - remove unversioned files

/// Manifest operations to perform.
enum Operation
{
	/// Invalid mode.
	none,

	/// Generate a manifest for a given target directory.
	generate,

	/// Verify file integrity of a directory according to its manifest.
	verify,

	/// Compare two manifested directories.
	compare,

	/// Update target directory to match source directory's manifest.
	update,

	/**
	 * Combination of `verify` and `update`.
	 * First performs `update` to pull changed files, then `verify`
	 * to validate data. If any files fail the validation check,
	 * `update` is run again to pull the latest files.
	 */
	repair,

	/// Copies manifest and tracked files from the source to the target.
	deploy
}

int main(string[] args)
{
	Operation mode;
	string sourcePath;
	string targetPath;

	try
	{
		auto result = getopt(args,
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
			defaultGetoptPrinter("Manifest generator.", result.options);

			stdout.writeln();
			stdout.writeln("Operation modes:");
			stdout.writeln(`	generate: Generate a manifest for a given target directory.`);
			stdout.writeln(`	  verify: Verify file integrity of a directory according to its manifest.`);
			stdout.writeln(`	 compare: Compare two manifested directories.`);
			stdout.writeln(`	  update: Update target directory to match source directory's manifest.`);
			stdout.writeln(`	  repair: Combination of "verify" and "update".`);
			stdout.writeln(`	          First performs "update" to pull changed files, then "verify"`);
			stdout.writeln(`	          to validate data. If any files fail the validation check,`);
			stdout.writeln(`	          "update" is run again to pull the latest files.`);

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
		final switch (mode) with (Operation)
		{
			case none:
				stderr.writeln("Invalid operation mode specified.");
				return -2;

			case generate:
				enforce(!targetPath.empty, "Target directory must be specified to generate a manifest.");

				generateManifest(targetPath);
				break;

			case verify:
				enforce(!targetPath.empty, "Target directory must be specified to verify a manifest.");

				verifyManifest(targetPath);
				break;

			case compare:
				enforce(!sourcePath.empty && !targetPath.empty,
				        "Source and target directories must both be specified for operation mode " ~ to!string(mode));

				compareManifests(sourcePath, targetPath);
				break;

			case update:
				enforce(!sourcePath.empty && !targetPath.empty,
				        "Source and target directories must both be specified for operation mode " ~ to!string(mode));

				applyManifest(sourcePath, targetPath);
				break;

			case repair:
				enforce(!sourcePath.empty && !targetPath.empty,
				        "Source and target directories must both be specified for operation mode " ~ to!string(mode));

				repairManifest(sourcePath, targetPath);
				break;

			case deploy:
				enforce(!sourcePath.empty && !targetPath.empty,
				        "Source and target directories must both be specified for operation mode " ~ to!string(mode));

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
	auto manifest = generator.generate(sourcePath);
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
				continue;

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
	auto manifest = Manifest.fromFile(buildNormalizedPath(sourcePath, manifestFileName));
	auto diff = generator.verify(sourcePath, manifest);

	printDiff(diff);
}

void compareManifests(string sourcePath, string targetPath)
{
	auto sourceManifest = Manifest.fromFile(buildNormalizedPath(sourcePath, manifestFileName));
	auto targetManifest = Manifest.fromFile(buildNormalizedPath(targetPath, manifestFileName));

	auto generator = new ManifestGenerator();
	auto diff = generator.diff(sourceManifest, targetManifest);

	printDiff(diff);
}

void applyManifest(string sourcePath, ManifestEntry[] sourceManifest, string targetPath, ManifestEntry[] targetManifest)
{
	auto generator = new ManifestGenerator();
	auto diff = generator.diff(sourceManifest, targetManifest);

	stderr.writeln("diff:");
	printDiff(diff);
	stderr.writeln();

	foreach (ManifestDiff entry; diff.filter!(x => x.state != ManifestState.unchanged))
	{
		final switch (entry.state)
		{
			// impossible, but `final switch`
			case ManifestState.unchanged:
				continue;

			case ManifestState.added:
			case ManifestState.changed:
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

			case ManifestState.removed:
				stderr.writeln("applying: ", entry.state, `: "`, entry.last.filePath, `"`);

				const toRemove = buildNormalizedPath(targetPath, entry.last.filePath);

				if (exists(toRemove))
				{
					remove(toRemove);
				}

				break;

			case ManifestState.moved:
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

	bool[string] sourceSet, targetSet;

	auto sourcePaths = sourceManifest.map!(x => to!string(dirName(x.filePath).asNormalizedPath));
	sourcePaths.each!(x => sourceSet[x] = true);

	auto targetPaths = targetManifest.map!(x => to!string(dirName(x.filePath).asNormalizedPath));
	targetPaths.each!(x => targetSet[x] = true);

	auto uniqueTargetPaths = targetSet.byKey
	                                  .array
	                                  .sort!((a, b) => a.count(dirSeparator) > b.count(dirSeparator));

	// grab all dirs unique to the old manifest
	auto oldDirs = uniqueTargetPaths.filter!(x => (x in sourceSet) is null)
	                                .map!(x => buildNormalizedPath(targetPath, x))
	                                .filter!(x => x.exists);

	// TODO: remove empty parent directories too

	// check each of them for any files
	foreach (dir; oldDirs)
	{
		size_t dirEntryCount;
		auto entries = dirEntries(dir, SpanMode.shallow);

		while (!entries.empty)
		{
			try
			{
				const entry = entries.front;
				++dirEntryCount;
			}
			catch (Exception ex)
			{
				// ok well I mean it's not empty then, and we can only assume it "exists",
				// even if it's e.g. a broken symlink
				++dirEntryCount;
			}

			entries.popFront();
		}

		// the folder doesn't have any files in it,
		// so just remove it.
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

	auto sourceManifest = Manifest.fromFile(sourceManifestPath);
	auto targetManifest = Manifest.fromFile(targetManifestPath);

	applyManifest(sourcePath, sourceManifest, targetPath, targetManifest);
}

void repairManifest(string sourcePath, string targetPath)
{
	auto generator = new ManifestGenerator();

	ManifestEntry[] sourceManifest = Manifest.fromFile(sourcePath.buildNormalizedPath(manifestFileName));

	auto targetManifestPath = targetPath.buildNormalizedPath(manifestFileName);

	// if a target manifest already exists
	if (exists(targetManifestPath))
	{
		ManifestEntry[] targetManifest = Manifest.fromFile(targetManifestPath);

		// first, perform a normal update
		applyManifest(sourcePath, sourceManifest, targetPath, targetManifest);

		stderr.writeln();
		stderr.writeln("verifying...");
		stderr.writeln();

		// now verify against the source manifest which whill match the target manifest
		auto diff = generator.verify(targetPath, sourceManifest);
		applyManifest(sourcePath, sourceManifest, targetPath, Manifest.fromDiff(diff));

		return;
	}

	auto diff = generator.verify(targetPath, sourceManifest);

	printDiff(diff);

	if (diff.all!(x => x.state == ManifestState.unchanged))
	{
		return;
	}

	stderr.writeln();
	stderr.writeln("repairing...");
	stderr.writeln();

	auto fakeManifest = Manifest.fromDiff(diff);

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

	auto sourceManifest = Manifest.fromFile(sourceManifestPath);
	applyManifest(sourcePath, sourceManifest, targetPath, null);
}
