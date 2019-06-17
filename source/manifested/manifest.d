module manifested.manifest;

import std.algorithm;
import std.array : array, empty;
import std.exception;
import std.file;
import std.path;
import std.range;
import std.stdio;
import std.string : replace, split, splitLines;
import std.uni : sicmp;

import symlinkd.symlink;

/// Finds the first element in a range that matches `pred`, or returns `null`
private auto firstOrDefault(alias pred, R)(R r) if (isInputRange!R)
{
	auto search = r.find!(pred)();

	if (!search.empty)
	{
		return search.takeOne.front;
	}

	return null;
}

/**
 * \brief 
 * Represents the difference between two \sa ManifestEntrys.
 */
public enum ManifestState
{
	/**
	 * \brief 
	 * The file is unchanged.
	 */
	unchanged,
	/**
	 * \brief 
	 * Indicates that a file has been moved, renamed, or both.
	 */
	moved,
	/**
	 * \brief 
	 * The file has been modified in some way.
	 */
	changed,
	/**
	 * \brief 
	 * The file has been added to the new manifest.
	 */
	added,
	/**
	 * \brief 
	 * The file has been removed from the new manifest.
	 */
	removed
}

/**
 * \brief 
 * Holds two instances of \sa ManifestEntry and their differences.
 * \sa ManifestState
 */
public class ManifestDiff
{
	/**
	 * \brief 
	 * The state of the file.
	 * \sa ManifestState
	 */
	public ManifestState state;
	/**
	 * \brief 
	 * The newer of the two entries.
	 */
	public ManifestEntry current;
	/**
	 * \brief 
	 * The older of the two entries.
	 */
	public ManifestEntry last;

	public this(ManifestState state, ManifestEntry current, ManifestEntry last)
	{
		this.state   = state;
		this.current = current;
		this.last    = last;
	}
}

/*
public class FilesIndexedEventArgs : EventArgs
{
	public this(int fileCount)
	{
		FileCount = fileCount;
	}

	public int FileCount;
}

public class FileHashEventArgs : EventArgs
{
	public this(string fileName, int fileIndex, int fileCount)
	{
		FileName  = fileName;
		FileIndex = fileIndex;
		FileCount = fileCount;
		Cancel    = false;
	}

	public string FileName;  // TODO: { get; }
	public int    FileIndex; // TODO: { get; }
	public int    FileCount; // TODO: { get; }
	public bool   Cancel;    // TODO: { get; set; }
}
*/

public class DirectoryNotFoundException : Exception
{
public:
	const string path;

	this(string directory)
	{
		path = directory;
		super("Directory not found: " ~ path);
	}
}

public class ManifestGenerator
{
	//public event EventHandler<FilesIndexedEventArgs> FilesIndexed;
	//public event EventHandler<FileHashEventArgs>     FileHashStart;
	//public event EventHandler<FileHashEventArgs>     FileHashEnd;

	/**
	 * \brief 
	 * Generates a manifest for a given directory hierarchy.
	 * \param dirPath The path to the directory.
	 * \return An array of \sa ManifestEntry.
	 */
	public ManifestEntry[] generate(string dirPath)
	{
		if (!exists(dirPath))
		{
			throw new DirectoryNotFoundException(dirPath);
		}

		ManifestEntry[] result;

		string[] fileIndex = dirEntries(dirPath, SpanMode.breadth)
		                     .filter!(x => !x.empty && x.isFile &&
		                              baseName(x) != ".manifest")
		                     .map!(x => cast(string)x)
		                     .array;

		if (fileIndex.empty)
		{
			return result;
		}

		//OnFilesIndexed(new FilesIndexedEventArgs(fileIndex.length));

		//size_t index;

		foreach (string f; fileIndex)
		{
			string relativePath = f[dirPath.length + 1 .. $];
			DirEntry file = getFileInfo(f);

			//++index;

			//auto args = new FileHashEventArgs(relativePath, index, fileIndex.length);
			//OnFileHashStart(args);

			//if (args.Cancel)
			//{
			//	return null;
			//}

			string hash = getFileHash(f);

			//args = new FileHashEventArgs(relativePath, index, fileIndex.length);
			//OnFileHashEnd(args);

			//if (args.Cancel)
			//{
			//	return null;
			//}

			result ~= new ManifestEntry(relativePath, file.size, hash);
		}

		return result;
	}

	/**
	 * \brief 
	 * Follows symbolic links and constructs a \sa DirEntry of the actual file.
	 * \param path Path to the file.
	 * \return The  of the real file.
	 */
	private static DirEntry getFileInfo(string path)
	{
		auto file = DirEntry(path);

		if (!file.isSymlink)
		{
			return file;
		}

		string reparsed = readSymlink(path);

		if (reparsed.empty)
		{
			version (Windows)
			{
				import core.sys.windows.windows : GetLastError;

				if (GetLastError() == 2)
				{
					throw new FileException(path, "Symlinked file not found!");
				}
			}

			throw new FileException(path, "Failed to read symlink target.");
		}

		return DirEntry(reparsed);
	}

	/**
	 * \brief 
	 * Generates a diff of two mod manifests.
	 * \param newManifest The new manifest.
	 * \param oldManifest The old manifest.
	 * \return A list of \sa ManifestDiff containing change information.
	 */
	public static ManifestDiff[] diff(ManifestEntry[] newManifest, ManifestEntry[] oldManifest)
	{
		// TODO: handle copies instead of moves to reduce download requirements (or cache downloads by hash?)

		ManifestDiff[] result;
		ManifestEntry[] old;

		if (oldManifest !is null && oldManifest.length > 0)
		{
			old = oldManifest.dup;
		}

		foreach (ManifestEntry entry; newManifest)
		{
			// First, check for an exact match. File path/name, hash, size; everything.
			const exact = old.firstOrDefault!(x => x == entry);

			if (exact !is null)
			{
				old = old.remove!(x => x == exact);
				result ~= new ManifestDiff(ManifestState.unchanged, entry, null);
				continue;
			}

			// There's no exact match, so let's search by checksum.
			ManifestEntry[] checksum = old.filter!(x => !sicmp(x.checksum, entry.checksum)).array;

			// If we've found matching checksums, we then need to check
			// the file path to see if it's been moved.
			if (checksum.length > 0)
			{
				foreach (ManifestEntry c; checksum)
				{
					old = old.remove!(x => x == c);
				}

				if (checksum.all!(x => x.filePath != entry.filePath))
				{
					const tbd = old.firstOrDefault!(x => !sicmp(x.filePath, entry.filePath));

					old = old.remove!(x => x == tbd);
					result ~= new ManifestDiff(ManifestState.moved, entry, checksum[0]);
					continue;
				}
			}

			// If we've made it here, there's no matching checksums, so let's search
			// for matching paths. If a path matches, the file has been modified.
			ManifestEntry nameMatch = old.firstOrDefault!(x => !sicmp(x.filePath, entry.filePath));

			if (nameMatch !is null)
			{
				old = old.remove!(x => x == nameMatch);
				result ~= new ManifestDiff(ManifestState.changed, entry, nameMatch);
				continue;
			}

			// In every other case, this file is newly added.
			result ~= new ManifestDiff(ManifestState.added, entry, null);
		}

		// All files that are still unique to the old manifest should be marked for removal.
		if (old.length > 0)
		{
			result ~= old.map!(x => new ManifestDiff(ManifestState.removed, x, null)).array;
		}

		return result;
	}

	/**
	 * \brief 
	 * Verifies the integrity of a mod against a mod manifest.
	 * \param dirPath Path to the directory containing the files to verify.
	 * \param manifest Manifest to check against.
	 * \return A list of \sa ManifestDiff containing change information.
	 */
	public ManifestDiff[] verify(string dirPath, ManifestEntry[] manifest)
	{
		ManifestDiff[] result;

		foreach (ManifestEntry m; manifest)
		{
			string filePath = buildNormalizedPath(dirPath, m.filePath);

			//++index;

			//auto args = new FileHashEventArgs(m.filePath, index, manifest.length);
			//OnFileHashStart(args);

			//if (args.Cancel)
			//{
			//	return null;
			//}

			//try
			//{
				if (!exists(filePath))
				{
					result ~= new ManifestDiff(ManifestState.removed, m, null);
					continue;
				}

				DirEntry info;

				try
				{
					info = getFileInfo(filePath);
				}
				catch (FileException)
				{
					result ~= new ManifestDiff(ManifestState.removed, m, null);
					continue;
				}

				if (info.size != m.fileSize)
				{
					result ~= new ManifestDiff(ManifestState.changed, m, null);
					continue;
				}

				string hash = getFileHash(filePath);
				
				if (sicmp(hash, m.checksum))
				{
					result ~= new ManifestDiff(ManifestState.changed, m, null);
					continue;
				}

				result ~= new ManifestDiff(ManifestState.unchanged, m, null);
			//}
			//finally
			//{
				//args = new FileHashEventArgs(m.filePath, index, manifest.length);
				//OnFileHashEnd(args);
			//}

			//if (args.Cancel)
			//{
			//	return null;
			//}
		}

		return result;
	}

	/**
	 * \brief 
	 * Computes a SHA-256 hash of a given file
	 * \param filePath Path to the file to hash.
	 * \return Lowercase string representation of the hash.
	 */
	public static string getFileHash(string filePath)
	{
		import std.digest.sha;

		ubyte[32] hash;
		SHA256 sha;

		auto f = File(filePath, "rb");

		foreach (chunk; f.byChunk(32*1024))
		{
			sha.put(chunk);
		}

		hash = sha.finish();
		return toHexString!(LetterCase.lower)(hash).idup;
	}

/*
	private void OnFilesIndexed(FilesIndexedEventArgs e)
	{
		if (FilesIndexed !is null)
		{
			FilesIndexed.Invoke(this, e);
		}
	}

	private void OnFileHashStart(FileHashEventArgs e)
	{
		if (FileHashStart !is null)
		{
			FileHashStart.Invoke(this, e);
		}
	}

	private void OnFileHashEnd(FileHashEventArgs e)
	{
		if (FileHashEnd !is null)
		{
			FileHashEnd.Invoke(this, e);
		}
	}
*/
}

public static class Manifest
{
	/**
	 * \brief 
	 * Produces a mod manifest from a file.
	 * \param filePath The path to the mod manifest file.
	 * \return List of \sa ManifestEntry
	 */
	public static ManifestEntry[] fromFile(string filePath)
	{
		string[] lines = readText(filePath).splitLines();
		return lines.map!(line => new ManifestEntry(line)).array;
	}

	/**
	 * \brief 
	 * Parses a mod manifest file in string form and produces a mod manifest.
	 * \param str The mod manifest file string to parse.
	 * \return List of \sa ManifestEntry
	 */
	public static ManifestEntry[] fromString(string str)
	{
		string[] lines = str.splitLines();
		return lines.map!(line => new ManifestEntry(line)).array;
	}

	/**
	 * \brief 
	 * Writes a mod manifest to a file.
	 * \param manifest The manifest to write.
	 * \param filePath The file to write the manifest to.
	 */
	public static void toFile(R)(R manifest, string filePath)
		if (isForwardRange!R && is(ElementType!R == ManifestEntry))
	{
		std.file.write(filePath, join(manifest.map!(x => x.toString()), "\n"));
	}
}

/**
 * \brief 
 * An entry in a mod manifest describing a file's path, size, and checksum.
 */
public class ManifestEntry
{
	/**
	 * \brief 
	 * The name/path of the file relative to the root of the mod directory.
	 */
	public string filePath;
	/**
	 * \brief 
	 * The size of the file in bytes.
	 */
	public const long fileSize;
	/**
	 * \brief 
	 * String representation of the SHA-256 checksum of the file.
	 */
	public const string checksum;

	/**
	 * \brief 
	 * Parses a line from a mod manifest line and constructs a \sa ManifestEntry .
	 * \param line 
	 * The line to parse.
	 * Each field of the line must be separated by tab (\t) and contain 3 fields total.
	 * Expected format is: [name]\t[size]\t[checksum]
	 */
	public this(string line)
	{
		string[] fields = line.split('\t');

		import std.conv : to;
		enforce(fields.length == 3, "Manifest line must have 3 fields. Provided: " ~ to!string(fields.length));

		this.filePath = fields[0];
		this.fileSize = to!long(fields[1]);
		this.checksum = fields[2];

		enforce(!isRooted(this.filePath), "Absolute paths are forbidden: " ~ this.filePath);
		enforce(!line.canFind(`..\`) && !line.canFind(`\..\`), "Parent directory traversal is forbidden: " ~ this.filePath);
	}

	public this(string filePath, long fileSize, string checksum)
	{
		this.filePath = filePath;
		this.fileSize = fileSize;
		this.checksum = checksum;
	}

	public override string toString() const
	{
		import std.format : format;
		return format!("%s\t%u\t%s")(filePath, fileSize, checksum);
	}

	public override bool opEquals(Object obj) const
	{
		if (obj is this)
		{
			return true;
		}

		auto m = cast(ManifestEntry)obj;

		if (m is null)
		{
			return false;
		}

		return fileSize == m.fileSize &&
		       !sicmp(filePath, m.filePath) &&
		       !sicmp(checksum, m.checksum);
	}

	public override size_t toHash() const
	{
		size_t hashCode = hashOf(filePath);
		hashCode = fileSize.hashOf(hashCode);
		hashCode = checksum.hashOf(hashCode);
		return hashCode;
	}
}
