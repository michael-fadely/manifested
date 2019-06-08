import std;

import manifested;

int main(string[] args)
{
	string inPath;

	try
	{
		auto result = getopt(args,
		                     "i|input", "Input directory", &inPath);

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

	auto generator = new ManifestGenerator();
	auto manA = Manifest.fromFile(buildNormalizedPath(inPath, "a.manifest"));
	auto manB = generator.generate(inPath);
	auto diff = generator.diff(manB, manA);

	foreach (entry; diff.filter!(x => x.state != ManifestState.unchanged))
	{
		auto last = entry.last;
		auto current = entry.current;

		if (last !is null && current !is null &&
		    last.filePath != current.filePath)
		{
			writeln(entry.last.filePath, " -> ", entry.current.filePath, ": ", entry.state);
		}
		else
		{
			auto e = last is null ? current : last;
			writeln(e.filePath, ": ", entry.state);
		}
	}

	/*
	auto generator = new ManifestGenerator();
	auto manifest = generator.generate(inPath);

	foreach (entry; manifest)
	{
		stdout.writeln(entry);
	}
	*/

	/*

	auto diff = generator.verify(inPath, manifest);
	auto modifications = diff.filter!(x => x.state != ManifestState.unchanged);

	foreach (entry; modifications)
	{
		auto last = entry.last;
		auto current = entry.current;

		if (last !is null && current !is null && last.filePath != current.filePath)
		{
			writeln(entry.last.filePath, " -> ", entry.current.filePath, ": ", entry.state);
		}
		else
		{
			auto e = last is null ? current : last;
			writeln(e.filePath, ": ", entry.state);
		}
	}

	*/

	return 0;
}
