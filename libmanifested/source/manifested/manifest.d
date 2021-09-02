module manifested.manifest;

import std.algorithm;
import std.array : Appender, array, empty;
import std.conv;
import std.exception;
import std.file;
import std.path;
import std.range;
import std.stdio;
import std.string : replace, split, splitLines, strip;
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
 * \brief Represents the difference between two \sa ManifestEntry instances.
 */
public enum ManifestState
{
	/**
	 * \brief The file is unchanged.
	 */
	unchanged,

	/**
	 * \brief Indicates that a file has been moved, renamed, or both.
	 */
	moved,

	/**
	 * \brief The file has been modified in some way.
	 */
	changed,

	/**
	 * \brief The file has been added to the new manifest.
	 */
	added,

	/**
	 * \brief The file has been removed from the new manifest.
	 */
	removed
}

/**
 * \brief Holds two instances of \sa ManifestEntry and their differences.
 * \sa ManifestState
 */
public class ManifestDiff
{
	/**
	 * \brief The state of the file.
	 * \sa ManifestState
	 */
	public ManifestState state;

	/**
	 * \brief The older of the two entries.
	 */
	public ManifestEntry last;

	/**
	 * \brief The newer of the two entries.
	 */
	public ManifestEntry current;

	public this(ManifestState state, ManifestEntry last, ManifestEntry current)
	{
		this.state   = state;
		this.last    = last;
		this.current = current;
	}
}

/// An exception which is thrown when a provided directory could not be found.
public class DirectoryNotFoundException : Exception
{
public:
	/// The directory path which wasn't found.
	const string path;

	this(string directory)
	{
		path = directory;
		super("Directory not found: " ~ path);
	}
}

/// Class for generating, verifying, and comparing manifests.
public class ManifestGenerator
{
	/**
	 * \brief Generates a manifest for a given directory hierarchy.
	 * \param dirPath The path to the directory.
	 * \return An array of \sa ManifestEntry.
	 */
	public ManifestEntry[] generate(string dirPath)
	{
		if (!exists(dirPath))
		{
			throw new DirectoryNotFoundException(dirPath);
		}

		// TODO: don't hard-code ".manifest"
		string[] fileIndex = dirEntries(dirPath, SpanMode.breadth)
		                     .filter!(x => !x.empty && x.isFile &&
		                              baseName(x) != ".manifest")
		                     .map!(x => cast(string)x)
		                     .array;

		if (fileIndex.empty)
		{
			return [];
		}

		Appender!(ManifestEntry[]) result;
		result.reserve(fileIndex.length);
		dirPath = dirPath.asNormalizedPath.array; // .array gives a string back

		foreach (string f; fileIndex)
		{
			string relative = f[dirPath.length + 1 .. $];
			DirEntry file = getFileInfo(f);

			string hash = getFileHash(f);

			result ~= new ManifestEntry(relative, file.size, hash);
		}

		return result[];
	}

	/**
	 * \brief Follows symbolic links and constructs a \sa DirEntry of the actual file.
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
	 * \brief Generates a diff of two manifests.
	 * \param newManifest The new manifest.
	 * \param oldManifest The old manifest.
	 * \return A list of \sa ManifestDiff containing change information.
	 */
	public static ManifestDiff[] diff(ManifestEntry[] newManifest, ManifestEntry[] oldManifest)
	{
		// TODO: handle copies instead of moves to reduce download requirements (or cache downloads by hash?)

		Appender!(ManifestDiff[]) result;
		ManifestEntry[] old; // TODO: use set (AA)

		if (oldManifest !is null && oldManifest.length > 0)
		{
			old = oldManifest.dup;
		}

		foreach (ManifestEntry newEntry; newManifest)
		{
			// First, check for an exact match. File path/name, hash, size; everything.
			const exact = old.firstOrDefault!(x => x == newEntry); // TODO: use set (AA)

			if (exact !is null)
			{
				old = old.remove!(x => x is exact); // TODO: use set (AA)
				result ~= new ManifestDiff(ManifestState.unchanged, newEntry, newEntry);
				continue;
			}

			// There's no exact match, so let's search by checksum.
			// (.array is used because all checksum matches are iterated below.)
			ManifestEntry[] checksumMatches = old.filter!(x => !sicmp(x.checksum, newEntry.checksum)).array;

			// If we've found matching checksums, we then need to check
			// the file path to see if it's been moved.
			if (checksumMatches.length > 0)
			{
				auto first = checksumMatches[0];
				old = old.remove!(x => x is first); // TODO: use set (AA)

				if (checksumMatches.all!(x => x.filePath != newEntry.filePath))
				{
					// TODO: produce lookup by name for speed
					const tbd = old.firstOrDefault!(x => x.filePath == newEntry.filePath);

					if (tbd !is null)
					{
						old = old.remove!(x => x is tbd); // TODO: use set (AA)
					}

					result ~= new ManifestDiff(ManifestState.moved, first, newEntry);
					continue;
				}
			}

			// If we've made it here, there's no matching checksums, so let's search
			// for matching paths. If a path matches, the file has been modified.
			// TODO: produce lookup by name for speed
			ManifestEntry nameMatch = old.firstOrDefault!(x => x.filePath == newEntry.filePath);

			if (nameMatch !is null)
			{
				old = old.remove!(x => x is nameMatch); // TODO: use set (AA)
				result ~= new ManifestDiff(ManifestState.changed, nameMatch, newEntry);
				continue;
			}

			// In every other case, this file is newly added.
			result ~= new ManifestDiff(ManifestState.added, null, newEntry);
		}

		// All files that are still unique to the old manifest should be marked for removal.
		if (old.length > 0)
		{
			result ~= old.map!(x => new ManifestDiff(ManifestState.removed, x, null));
		}

		result.shrinkTo(result[].length);
		return result[];
	}

	/**
	 * \brief Verifies the integrity of a directory tree against a manifest.
	 * \param dirPath Path to the directory containing the files to verify.
	 * \param manifest Manifest to check against.
	 * \return A list of \sa ManifestDiff containing change information.
	 */
	public ManifestDiff[] verify(string dirPath, ManifestEntry[] manifest)
	{
		Appender!(ManifestDiff[]) result;

		foreach (ManifestEntry m; manifest)
		{
			string filePath = buildNormalizedPath(dirPath, m.filePath);

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
				// this null checksum should raise red flags and e.g force a copy on
				// manifest application
				auto newEntry = new ManifestEntry(m.filePath, info.size, null);
				result ~= new ManifestDiff(ManifestState.changed, m, newEntry);
				continue;
			}

			string hash = getFileHash(filePath);
			
			if (sicmp(hash, m.checksum) != 0)
			{
				auto newEntry = new ManifestEntry(m.filePath, info.size, hash);
				result ~= new ManifestDiff(ManifestState.changed, m, newEntry);
				continue;
			}

			result ~= new ManifestDiff(ManifestState.unchanged, m, m);
		}

		result.shrinkTo(result[].length);
		return result[];
	}

	/**
		Computes a SHA-256 hash of a given file.

		Params:
			filePath  = Path to the file to hash.
			chunkSize = The size of each chunk read from the file.
		
		Returns:
			Lowercase string representation of the hash.
	 */
	private static string getFileHash(string filePath, size_t chunkSize = 32 * 1024)
	{
		import std.digest.sha : SHA256, toHexString, LetterCase;

		ubyte[32] hash;
		SHA256 sha;

		auto f = File(filePath, "rb");

		foreach (chunk; f.byChunk(chunkSize))
		{
			sha.put(chunk);
		}

		hash = sha.finish();
		return toHexString!(LetterCase.lower)(hash).idup;
	}
}

/// Class for parsing and writing manifest files.
public static class Manifest
{
	/**
	 * \brief Produces a manifest from a file.
	 * \param filePath The path to the manifest file.
	 * \return List of \sa ManifestEntry
	 */
	public static ManifestEntry[] fromFile(string filePath)
	{
		// TODO: just return a range
		string[] lines = readText(filePath).splitLines();
		return lines.map!(line => new ManifestEntry(line)).array;
	}

	/**
	 * \brief Parses a manifest file in string form and produces a manifest.
	 * \param str The manifest file string to parse.
	 * \return List of \sa ManifestEntry
	 */
	public static ManifestEntry[] fromString(string str)
	{
		// TODO: just return a range
		string[] lines = str.splitLines();
		return lines.map!(line => new ManifestEntry(line)).array;
	}

	/// Given a diff, produces a manifest of the non-removed entries.
	// TODO: use range instead of array
	public static ManifestEntry[] fromDiff(ManifestDiff[] diff)
	{
		// TODO: just return a range
		return diff.filter!(x => x.state != ManifestState.removed)
		           .map!(x => x.current)
		           .array;
	}

	/**
	 * \brief Writes a manifest to a file.
	 * \param manifest The manifest to write.
	 * \param filePath The file to write the manifest to.
	 */
	public static void toFile(R)(R manifest, string filePath) if (isForwardRange!R && is(ElementType!R == ManifestEntry))
	{
		std.file.write(filePath, join(manifest.map!(x => x.toString()), "\n"));
	}

	// TODO: use range instead of array
	/**
		Get all distinct directories from an old manifest which no longer exist in a new manifest.

		Params:
			oldManifest = The old manifest.
			newManifest = The new manifest.

		Returns:
			All distinct directories exclusive to `oldManifest` in descending order
			sorted by number of directory separators.
	 */
	public static string[] getOldDirectories(ManifestEntry[] oldManifest, ManifestEntry[] newManifest)
	{
		auto getDistinctPaths(ManifestEntry[] manifest)
		{
			bool[string] set;

			foreach (ManifestEntry entry; manifest)
			{
				string path = to!string(dirName(entry.filePath).asNormalizedPath);
				set[path] = true;
			}

			return set.keys.array;
		}

		bool[string] newDirectories;

		foreach (string newPath; getDistinctPaths(newManifest))
		{
			string path = newPath;

			do
			{
				newDirectories[path] = true;
				path = dirName(path);
			} while (path.length && path != ".");
		}

		string[] result = getDistinctPaths(oldManifest).filter!(s => (s in newDirectories) is null)
		                                               .array;

		result.sort!((a, b) => a.count(dirSeparator) > b.count(dirSeparator));

		return result;
	}
}

/// An entry in a manifest describing a file's path, size, and checksum.
public class ManifestEntry
{
	/// The name/path of the file relative to the root of the directory.
	public string filePath;

	/// The size of the file in bytes.
	public const long fileSize;

	/// String representation of the SHA-256 checksum of the file.
	public const string checksum; // TODO: change to ubyte[]

	/// Directory separator used in manifests. This remains constant on all platforms.
	public static const string pathSeparator = "/";

	/**
	 * \brief Parses a line from a manifest and constructs a \sa ManifestEntry .
	 * \param line The line to parse.
	 * Each field of the line must be separated by tab (\t) and contain 3 fields total.
	 * Expected format is: [name]\t[size]\t[checksum]
	 */
	public this(string line)
	{
		string[] fields = line.splitter('\t').map!(strip).array;

		enforce(fields.length == 3, "Manifest line must have 3 fields. Provided: " ~ to!string(fields.length));

		this.filePath = fields[0];
		this.fileSize = to!long(fields[1]);
		this.checksum = fields[2];

		validateFilePath();
	}

	/**
		Construct a pre-parsed manifest entry.

		Params:
			filePath = The name/path of the file relative to the root of the directory.
			fileSize = The size of the file in bytes.
			checksum = String representation of the SHA-256 checksum of the file.
	*/
	public this(string filePath, long fileSize, string checksum)
	{
		this.filePath = filePath;
		this.fileSize = fileSize;
		this.checksum = checksum;

		validateFilePath();
	}

	private void validateFilePath()
	{
		static if (dirSeparator != pathSeparator)
		{
			filePath = filePath.replace(dirSeparator, pathSeparator);
		}

		enforce(!isRooted(this.filePath), "Absolute paths are forbidden: " ~ this.filePath);
		enforce(!this.filePath.canFind(`..` ~ pathSeparator) && !this.filePath.canFind(pathSeparator ~ `..` ~ pathSeparator),
		        "Parent directory traversal is forbidden: " ~ this.filePath);
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
		       filePath == m.filePath &&
		       !sicmp(checksum, m.checksum);
	}

	public override size_t toHash() const @safe @nogc
	{
		size_t hashCode = hashOf(filePath);
		hashCode = hashOf(fileSize, hashCode);
		hashCode = hashOf(checksum, hashCode);
		return hashCode;
	}
}
