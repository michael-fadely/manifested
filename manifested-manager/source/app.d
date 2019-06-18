import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.stdio;

import manifested;

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
		                     "m|mode",   "Operation to perform.", &mode,
		                     "s|source", "Source directory.",     &sourcePath,
		                     "t|target", "Target directory.",     &targetPath);

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
				enforce(!sourcePath.empty, "Source directory must be specified to generate a manifest.");
				if (!generateManifest(sourcePath))
				{
					return -3;
				}

				break;

			case verify:
				enforce(!sourcePath.empty, "Source directory must be specified to verify a manifest.");

				if (!verifyManifest(sourcePath))
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
		}
	}
	catch (Exception ex)
	{
		stderr.writeln(ex.msg);
		return -1;
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
			case ManifestState.removed:
				stdout.writeln(entry.state, `: "`, entry.current.filePath, `"`);
				break;

			case ManifestState.moved:
				stdout.writeln(entry.state, `: "`, entry.last.filePath, `" -> "`, entry.current.filePath, `"`);
				break;
		}
	}

	if (!n)
	{
		stdout.writeln("no change");
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

bool applyManifest(string sourcePath, string targetPath)
{
	string sourceManifestPath = buildNormalizedPath(sourcePath, manifestFileName);
	string targetManifestPath = buildNormalizedPath(targetPath, manifestFileName);
	auto sourceManifest = Manifest.fromFile(sourceManifestPath);
	auto targetManifest = Manifest.fromFile(targetManifestPath);

	auto generator = new ManifestGenerator();
	auto diff = generator.diff(sourceManifest, targetManifest);

	// TODO: track empty dirs, remove if empty (with consideration for untracked files)

	foreach (ManifestDiff entry; diff.filter!(x => x.state != ManifestState.unchanged))
	{
		final switch (entry.state)
		{
			// impossible, but `final switch`
			case ManifestState.unchanged:
				continue;

			case ManifestState.added:
			case ManifestState.changed:
				stdout.writeln(entry.state, `: "`, entry.current.filePath, `"`);

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
				stdout.writeln(entry.state, `: "`, entry.current.filePath, `"`);

				auto toRemove = buildNormalizedPath(targetPath, entry.current.filePath);

				if (exists(toRemove))
				{
					remove(buildNormalizedPath(targetPath, entry.current.filePath));
				}
				break;

			case ManifestState.moved:
				stdout.writeln(entry.state, `: "`, entry.last.filePath, `" -> "`, entry.current.filePath, `"`);

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

	// when all is said and done, copy the manifest from the source to the target
	copy(sourceManifestPath, targetManifestPath);

	return true;
}
