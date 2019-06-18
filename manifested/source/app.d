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

// TODO: consider different names for these
enum Operation
{
	/// Invalid mode.
	none,
	/// Generate a manifest for a given source directory.
	generate,
	/// Verify file integrity according to the manifested directory.
	verify,
	/// Compare two manifested directories.
	compare,
	/// Update target directory to match source directory's manifest.
	apply,
	/// Combination of `verify` and `apply`.
	/// Take manifest from source, verify findings, and apply changes where applicable.
	repair,
	/// Deploys a source to a target destination according to the manifest.
	deploy

	// TODO: clean - remove unversioned files
}

int main(string[] args)
{
	Operation mode;
	string sourcePath;
	string targetPath;

	try
	{
		auto result = getopt(args,
		                     "m|mode",   "Operation to perform.",               &mode,
		                     "s|source", "Source directory for the operation.", &sourcePath,
		                     "t|target", "Target directory of the operation.",  &targetPath);

		if (result.helpWanted)
		{
			defaultGetoptPrinter("Manifest generator.", result.options);
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
		if (!sourcePath.empty)
		{
			enforce(exists(sourcePath), "Source path does not exist.");
		}

		if (!targetPath.empty)
		{
			enforce(exists(targetPath), "Target path does not exist.");
		}

		final switch (mode) with (Operation)
		{
			case none:
				stderr.writeln("Invalid operation mode specified.");
				return -2;

			case generate:
				enforce(!targetPath.empty, "Source directory must be specified to generate a manifest.");
				if (!generateManifest(targetPath))
				{
					return -3;
				}

				break;

			case verify:
				enforce(!targetPath.empty, "Source directory must be specified to verify a manifest.");

				if (!verifyManifest(targetPath))
				{
					return -4;
				}

				break;

			case compare:
				enforce(!sourcePath.empty && !targetPath.empty,
				        "Source and target directories must both be specified for operation mode " ~ to!string(mode));

				if (!compareManifests(sourcePath, targetPath))
				{
					return -5;
				}

				break;

			case apply:
				enforce(!sourcePath.empty && !targetPath.empty,
				        "Source and target directories must both be specified for operation mode " ~ to!string(mode));

				if (!applyManifest(sourcePath, targetPath))
				{
					return -6;
				}

				break;

			case repair:
				enforce(!sourcePath.empty && !targetPath.empty,
				        "Source and target directories must both be specified for operation mode " ~ to!string(mode));

				if (!repairManifest(sourcePath, targetPath))
				{
					return -7;
				}

				break;

			case deploy:
				enforce(!sourcePath.empty && !targetPath.empty,
				        "Source and target directories must both be specified for operation mode " ~ to!string(mode));

				if (!deployManifest(sourcePath, targetPath))
				{
					return -8;
				}

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
		stdout.writeln();
		stdout.writeln("press enter to exit");
		stdin.readln();
	}

	return 0;
}

private:

const manifestFileName = ".manifest";

bool generateManifest(string sourcePath)
{
	auto generator = new ManifestGenerator();
	auto manifest = generator.generate(sourcePath);
	Manifest.toFile(manifest, buildNormalizedPath(sourcePath, manifestFileName));
	return true;
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
				stdout.writeln(entry.state, `: "`, entry.current.filePath, `"`);
				break;

			case ManifestState.removed:
				stdout.writeln(entry.state, `: "`, entry.last.filePath, `"`);
				break;

			case ManifestState.moved:
				stdout.writeln(entry.state, `: "`, entry.last.filePath, `" -> "`, entry.current.filePath, `"`);
				break;
		}
	}

	if (!n)
	{
		stdout.writeln("integrity OK");
	}
}

bool verifyManifest(string sourcePath)
{
	auto generator = new ManifestGenerator();
	auto manifest = Manifest.fromFile(buildNormalizedPath(sourcePath, manifestFileName));
	auto diff = generator.verify(sourcePath, manifest);

	printDiff(diff);

	return true;
}

bool compareManifests(string sourcePath, string targetPath)
{
	auto sourceManifest = Manifest.fromFile(buildNormalizedPath(sourcePath, manifestFileName));
	auto targetManifest = Manifest.fromFile(buildNormalizedPath(targetPath, manifestFileName));

	auto generator = new ManifestGenerator();
	auto diff = generator.diff(targetManifest, sourceManifest);

	printDiff(diff);

	return true;
}

void applyManifest(string sourcePath, ManifestEntry[] sourceManifest, string targetPath, ManifestEntry[] targetManifest)
{
	auto generator = new ManifestGenerator();
	auto diff = generator.diff(sourceManifest, targetManifest);

	stdout.writeln("diff:");
	printDiff(diff);
	stdout.writeln();

	foreach (ManifestDiff entry; diff.filter!(x => x.state != ManifestState.unchanged))
	{
		final switch (entry.state)
		{
			// impossible, but `final switch`
			case ManifestState.unchanged:
				continue;

			case ManifestState.added:
			case ManifestState.changed:
				stdout.writeln("applying: ", entry.state, `: "`, entry.current.filePath, `"`);

				auto sourceFile = buildNormalizedPath(sourcePath, entry.current.filePath);
				auto targetFile = buildNormalizedPath(targetPath, entry.current.filePath);

				auto targetDir = dirName(targetFile);

				if (!exists(targetDir))
				{
					mkdirRecurse(targetDir);
				}

				copy(sourceFile, targetFile);
				break;

			case ManifestState.removed:
				stdout.writeln("applying: ", entry.state, `: "`, entry.last.filePath, `"`);

				auto toRemove = buildNormalizedPath(targetPath, entry.last.filePath);

				if (exists(toRemove))
				{
					remove(toRemove);
				}
				break;

			case ManifestState.moved:
				stdout.writeln("applying: ", entry.state, `: "`, entry.last.filePath, `" -> "`, entry.current.filePath, `"`);

				auto from = buildNormalizedPath(targetPath, entry.last.filePath);
				auto to   = buildNormalizedPath(targetPath, entry.current.filePath);

				if (!exists(from))
				{
					stdout.writeln("missing! Treating as new!");
					goto case ManifestState.added;
				}

				auto toDir = dirName(to);

				if (!exists(toDir))
				{
					mkdirRecurse(toDir);
				}

				rename(from, to);
				break;
		}
	}

	// oh god... sort by deepest (unique) dir level to highest
	auto sourceDirs = sourceManifest
		.map!(x => to!string(dirName(x.filePath).asNormalizedPath))
		.array
		.sort
		.uniq
		.array
		.sort!((a, b) => a.count(dirSeparator) > b.count(dirSeparator));

	// OH GOD
	auto targetDirs = targetManifest
		.map!(x => to!string(dirName(x.filePath).asNormalizedPath))
		.array
		.sort
		.uniq
		.array
		.sort!((a, b) => a.count(dirSeparator) > b.count(dirSeparator));

	// grab all dirs unique to the old manifest
	auto oldDirs = targetDirs.filter!(x => !sourceDirs.canFind!((a, b) => a == b)(x))
	                         .map!(x => targetPath.buildNormalizedPath(x))
	                         .filter!(x => x.exists);

	// check each of them for any files
	foreach (dir; oldDirs)
	{
		size_t fileCount;
		auto entries = dirEntries(dir, SpanMode.shallow);

		while (!entries.empty)
		{
			try
			{
				auto entry = entries.front;

				if (entry.isFile)
				{
					++fileCount;
				}
			}
			catch (Exception ex)
			{
				// ok well I mean it's not empty then,
				// and we can only assume it's a file
				++fileCount;
			}

			entries.popFront();
		}

		// the folder doesn't have any files in it,
		// so just remove it.
		if (!fileCount)
		{
			rmdir(dir);
		}
	}

	// when all is said and done, copy the manifest from the source to the target
	copy(sourcePath.buildNormalizedPath(manifestFileName), targetPath.buildNormalizedPath(manifestFileName));
}

bool applyManifest(string sourcePath, string targetPath)
{
	string sourceManifestPath = buildNormalizedPath(sourcePath, manifestFileName);
	string targetManifestPath = buildNormalizedPath(targetPath, manifestFileName);

	enforce(exists(sourceManifestPath), "Source directory is missing its manifest!");
	enforce(exists(targetManifestPath), "Target directory is missing its manifest!");

	auto sourceManifest = Manifest.fromFile(sourceManifestPath);
	auto targetManifest = Manifest.fromFile(targetManifestPath);

	applyManifest(sourcePath, sourceManifest, targetPath, targetManifest);

	return true;
}

bool repairManifest(string sourcePath, string targetPath)
{
	auto generator = new ManifestGenerator();

	ManifestEntry[] sourceManifest = Manifest.fromFile(sourcePath.buildNormalizedPath(manifestFileName));

	auto targetManifestPath = targetPath.buildNormalizedPath(manifestFileName);

	// if a target manifest already exists
	if (exists(targetManifestPath))
	{
		ManifestEntry[] targetManifest = Manifest.fromFile(targetManifestPath);

		// first, perform a normal upgrade
		applyManifest(sourcePath, sourceManifest, targetPath, targetManifest);

		stdout.writeln();
		stdout.writeln("verifying...");
		stdout.writeln();

		// now verify against the source manifest which whill match the target manifest
		auto diff = generator.verify(targetPath, sourceManifest);
		applyManifest(sourcePath, sourceManifest, targetPath, Manifest.fromDiff(diff));

		return true;
	}

	auto diff = generator.verify(targetPath, sourceManifest);

	printDiff(diff);

	if (diff.all!(x => x.state == ManifestState.unchanged))
	{
		return true;
	}

	stdout.writeln();
	stdout.writeln("repairing...");
	stdout.writeln();

	auto fakeManifest = Manifest.fromDiff(diff);

	applyManifest(sourcePath, sourceManifest, targetPath, fakeManifest);
	return true;
}

bool deployManifest(string sourcePath, string targetPath)
{
	string sourceManifestPath = buildNormalizedPath(sourcePath, manifestFileName);

	enforce(exists(sourceManifestPath), "Source directory is missing its manifest!");

	if (!exists(targetPath))
	{
		mkdirRecurse(targetPath);
	}

	auto sourceManifest = Manifest.fromFile(sourceManifestPath);
	applyManifest(sourcePath, sourceManifest, targetPath, null);
	return true;
}