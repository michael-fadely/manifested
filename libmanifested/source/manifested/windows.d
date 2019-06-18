module manifested.windows;

version (Windows):

import core.sys.windows.windows;

import std.conv : to;
import std.exception;
import std.traits : ReturnType;

public class Win32Exception : Exception
{
public:
	/// The error code returned by `GetLastError`.
	const ReturnType!GetLastError errorCode;

	this()
	{
		errorCode = GetLastError();
		super("Operation failed with error code " ~ to!string(errorCode));
	}

	this(string msg)
	{
		errorCode = GetLastError();
		super("[" ~ to!string(errorCode) ~ "] " ~ msg);
	}
}
