import std;

import manifested;

int main(string[] args)
{
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

	
}
