module manifested.windows;

version (Windows):

import core.sys.windows.windows;

import std.conv : to;
import std.exception;
import std.traits : ReturnType;

public class Win32Exception : Exception
{
public:
	const ReturnType!GetLastError errorCode;

	this()
	{
		errorCode = GetLastError();
		super("Operation failed with error code " ~ to!string(errorCode));
	}
}

extern (Windows) nothrow @nogc
{
	uint GetFinalPathNameByHandleA(HANDLE hFile, LPSTR lpszFilePath, uint cchFilePath, uint dwFlags);
	uint GetFinalPathNameByHandleW(HANDLE hFile, LPWSTR lpszFilePath, uint cchFilePath, uint dwFlags);

	alias GetFinalPathNameByHandle = GetFinalPathNameByHandleW;
}

string getFinalPathName(string path)
{
	import std.string : toStringz;

	auto handle = CreateFileA(path.toStringz(), FILE_READ_EA, GENERIC_READ | GENERIC_WRITE | DELETE, null,
	                          OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);

	scope (exit) CloseHandle(handle);

	if (handle == INVALID_HANDLE_VALUE)
	{
		throw new Win32Exception();
	}

	auto sb = new char[1024];
	const uint result = GetFinalPathNameByHandleA(handle, sb.ptr, cast(uint)sb.length, 0);

	if (result == 0)
	{
		throw new Win32Exception();
	}

	return to!string(sb);
}
