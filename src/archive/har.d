/**
HAR - Human Archive Format

https://github.com/marler8997/har

HAR is a simple format to represent multiple files in a single block of text, i.e.
---
--- main.d
import foo;
void main()
{
    foofunc();
}
--- foo.d
module foo;
void foofunc()
{
}
---
*/
module archive.har;

import std.typecons : Flag, Yes, No;
import std.array : Appender, join;
import std.format : format;
import std.string : startsWith, indexOf, stripRight;
import std.utf : decode, replacementDchar;
import std.path : dirName, buildPath, pathSplitter;
import std.file : dirEntries, DirEntry, exists, isDir, mkdirRecurse, SpanMode;
import std.stdio : File;

class HarException : Exception
{
    this(string msg, string file, size_t line)
    {
        super(msg, file, line);
    }
}

struct HarExtractor
{
    string filenameForErrors;
    string outputDir;

    private bool verbose;
    private File verboseFile;

    bool dryRun;

    private size_t lineNumber;
    private void extractMkdir(string dir, Flag!"forEmptyDir" forEmptyDir)
    {
        if (exists(dir))
        {
            if (!isDir(dir))
            {
                if (forEmptyDir)
                    throw harFileException("cannot extract empty directory %s since it already exists as non-directory",
                        dir.formatDir);
                throw harFileException("cannot extract files to non-directory %s", dir.formatDir);
            }
        }
        else
        {
            if (verbose)
                verboseFile.writefln("mkdir %s", dir.formatDir);
            if (!dryRun)
                mkdirRecurse(dir);
        }
    }

    void enableVerbose(File verboseFile)
    {
        this.verbose = true;
        this.verboseFile = verboseFile;
    }

    void extractFromFile(T)(string harFilename, T fileInfoCallback)
    {
        this.filenameForErrors = harFilename;
        auto harFile = File(harFilename, "r");
        extract(harFile.byLine(Yes.keepTerminator), fileInfoCallback);
    }

    void extract(T, U)(T lineRange, U fileInfoCallback)
    {
        if (outputDir is null)
            outputDir = "";

        lineNumber = 1;
        if (lineRange.empty)
            throw harFileException("file is empty");

        auto line = lineRange.front;
        auto firstLineSpaceIndex = line.indexOf(' ');
        if (firstLineSpaceIndex <= 0)
            throw harFileException("first line does not start with a delimiter ending with a space");

        auto delimiter = line[0 .. firstLineSpaceIndex + 1].idup;

    LfileLoop:
        for (;;)
        {
            auto fileInfo = parseFileLine(line[delimiter.length .. $], delimiter[0]);
            auto fullFileName = buildPath(outputDir, fileInfo.filename);
            fileInfoCallback(fullFileName, fileInfo);

            if (fullFileName[$-1] == '/')
            {
                if (!dryRun)
                    extractMkdir(fullFileName, Yes.forEmptyDir);
                lineRange.popFront();
                if (lineRange.empty)
                    break;
                lineNumber++;
                line = lineRange.front;
                if (!line.startsWith(delimiter))
                    throw harFileException("expected delimiter after empty directory");
                continue;
            }

            {
                auto dir = dirName(fileInfo.filename);
                if (dir.length > 0)
                {
                    auto fullDir = buildPath(outputDir, dir);
                    extractMkdir(fullDir, No.forEmptyDir);
                }
            }
            if (verbose)
                verboseFile.writefln("creating %s", fullFileName.formatFile);
            {
                File currentOutputFile;
                if (!dryRun)
                    currentOutputFile = File(fullFileName, "w");
                scope(exit)
                {
                    if (!dryRun)
                        currentOutputFile.close();
                }
                for (;;)
                {
                    lineRange.popFront();
                    if (lineRange.empty)
                        break LfileLoop;
                    lineNumber++;
                    line = lineRange.front;
                    if (line.startsWith(delimiter))
                        break;
                    if (!dryRun)
                        currentOutputFile.write(line);
                }
            }
        }
    }
    private HarException harFileException(T...)(string fmt, T args) if (T.length > 0)
    {
        return harFileException(format(fmt, args));
    }
    private HarException harFileException(string msg)
    {
        return new HarException(msg, filenameForErrors, lineNumber);
    }

    FileProperties parseFileLine(const(char)[] line, char firstDelimiterChar)
    {
        if (line.length == 0)
            throw harFileException("missing filename");

        const(char)[] filename;
        const(char)[] rest;
        if (line[0] == '"')
        {
            size_t afterFileIndex;
            filename = parseQuotedFilename(line[1 .. $], &afterFileIndex);
            rest = line[afterFileIndex .. $];
        }
        else
        {
            filename = parseFilename(line);
            rest = line[filename.length .. $];
        }
        for (;;)
        {
            rest = skipSpaces(rest);
            if (rest.length == 0 || rest == "\n" || rest == "\r" || rest == "\r\n" || rest[0] == firstDelimiterChar)
                break;
            throw harFileException("properties not implemented '%s'", rest);
        }
        return FileProperties(filename);
    }

    void checkComponent(const(char)[] component)
    {
        if (component.length == 0)
            throw harFileException("invalid filename, contains double slash '//'");
        if (component == "..")
            throw harFileException("invalid filename, contains double dot '..' parent directory");
    }

    inout(char)[] parseFilename(inout(char)[] line)
    {
        if (line.length == 0 || isEndOfFileChar(line[0]))
            throw harFileException("missing filename");

        if (line[0] == '/')
            throw harFileException("absolute filenames are invalid");

        size_t start = 0;
        size_t next = 0;
        while (true)
        {
            auto cIndex = next;
            auto c = decode!(Yes.useReplacementDchar)(line, next);
            if (c == replacementDchar)
                throw harFileException("invalid utf8 sequence");

            if (c == '/')
            {
                checkComponent(line[start .. cIndex]);
                if (next >= line.length)
                    return line[0 .. next];
                start = next;
            }
            else if (isEndOfFileChar(c))
            {
                checkComponent(line[start .. cIndex]);
                return line[0 .. cIndex];
            }

            if (next >= line.length)
            {
                checkComponent(line[start .. next]);
                return line[0 ..next];
            }
        }
    }

    inout(char)[] parseQuotedFilename(inout(char)[] line, size_t* afterFileIndex)
    {
        if (line.length == 0)
            throw harFileException("filename missing end-quote");
        if (line[0] == '"')
            throw harFileException("empty filename");
        if (line[0] == '/')
            throw harFileException("absolute filenames are invalid");

        size_t start = 0;
        size_t next = 0;
        while(true)
        {
            auto cIndex = next;
            auto c = decode!(Yes.useReplacementDchar)(line, next);
            if (c == replacementDchar)
                throw harFileException("invalid utf8 sequence");

            if (c == '/')
            {
                checkComponent(line[start .. cIndex]);
                start = next;
            }
            else if (c == '"')
            {
                checkComponent(line[start .. cIndex]);
                *afterFileIndex = next + 1;
                return line[0 .. cIndex];
            }
            if (next >= line.length)
                throw harFileException("filename missing end-quote");
        }
    }
}

private inout(char)[] skipSpaces(inout(char)[] str)
{
    size_t i = 0;
    for (; i < str.length; i++)
    {
        if (str[i] != ' ')
            break;
    }
    return str[i .. $];
}

private bool isEndOfFileChar(C)(const(C) c)
{
    return c == '\n' || c == ' ' || c == '\r';
}

struct FileProperties
{
    const(char)[] filename;
}

auto formatDir(const(char)[] dir)
{
    if (dir.length == 0)
        dir = ".";

    return formatQuotedIfSpaces(dir);
}
auto formatFile(const(char)[] file)
  in { assert(file.length > 0); } do
{
    return formatQuotedIfSpaces(file);
}

// returns a formatter that will print the given string.  it will print
// it surrounded with quotes if the string contains any spaces.
auto formatQuotedIfSpaces(T...)(T args)
if (T.length > 0)
{
    struct Formatter
    {
        T args;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            import std.string : indexOf;
            bool useQuotes = false;
            foreach (arg; args)
            {
                if (arg.indexOf(' ') >= 0)
                {
                    useQuotes = true;
                    break;
                }
            }

            if (useQuotes)
                sink(`"`);
            foreach (arg; args)
                sink(arg);
            if (useQuotes)
                sink(`"`);
        }
    }
    return Formatter(args);
}

/// Builder for a new HAR archive file
struct HarCompressor
{
    /// The generated HAR file
    private File archive;

    /// The delimiter to use
    const string delimiter;

    /// Include the supported file properties in the file header
    bool includeAttributes;

    /// File system attributes
    static struct Attributes
    {
        ///
        string owner;

        ///
        uint permissions;
    }

    /++
     + Create a new instance that writes to the file denoted by `path`.
     +
     + Params:
     +   path = the output file
     +   delimiter = the delimiter for invidividual files (optional)
     +/
    this(scope const string path, return const string delimiter = "---")
    {
        this.archive = File(path, "w");
        this.delimiter = delimiter;
    }

    /++
     + Create a new instance that writes to `file`.
     +
     + Params:
     +   path = the output file (must be open for writing)
     +   delimiter = the delimiter for invidividual files (optional)
     +/
    this(ref File file, return const string delimiter = "---")
    {
        assert(file.isOpen());
        this.archive = file;
        this.delimiter = delimiter;
    }

    /++
     + Add the members of the directory denoted by `path` to the archive.
     +
     + This methods sequentially includes all files found in the directory (and
     + nested directories). Creates an explicit entry for the directory only iff
     + the directory is empty (as a directory is usually implied by its members).
     +
     + Params:
     +   path = the directory
     +/
    void addDirectory(scope const string path)
    {
        assert(isDir(path));

        auto entries = dirEntries(path, SpanMode.shallow);

        // Generate a named entry for empty directories
        if (entries.empty)
        {
            writeEmptyDirectoryHeader(path, getAttributes(path));
            return;
        }

        foreach (entry; entries)
        {
            if (entry.isDir)
                addDirectory(entry);
            else
                includeFile(entry, getAttributes(entry));
        }
    }

    /++
     + Add a new empty directory to the archive.
     +
     + Params:
     +   path       = the directory
     +   attributes = the file attributes (`owner`, ...) to use for `includeAttributes`
     +/
    void createEmptyDirectory(scope string path, scope lazy Attributes attributes = Attributes.init)
    {
        writeEmptyDirectoryHeader(path, attributes);
    }

    /// Add an existing file to the archive,
    void addFile(scope const string path)
    {
        includeFile(path, getAttributes(path));
    }

    /++
     + Add a new file with the specified lines to the archive. Each line will be
     + terminated with the host-specific line ending (either `\n` or `\r\n`).
     +
     + Params:
     +   path       = the file
     +   lines      = the individual lines of the file
     +   attributes = the file attributes (`owner`, ...) to use for `includeAttributes`
     +/
    void createFile(T)(scope const string path, T lines, scope lazy Attributes attributes = Attributes.init)
    {
        writeHeader(path, attributes);

        foreach (line; lines)
            archive.writeln(line);
        archive.writeln();
    }

    /// Flush buffered data to the archive
    void flush()
    {
        archive.flush();
    }

private:
    /++
     + Writes the header for a file/directory to the archive.
     +
     + Params:
     +   path       = the entire file path (elements are joined)
     +   attributes = the file attributes (`owner`, ...) to use for `includeAttributes`
     +/
    void writeHeader(T...)(scope T path, scope lazy Attributes attributes)
    {
        // Normalize Windows paths to use / instead of \
        version (Windows)
            auto quoted = formatQuotedIfSpaces(path[0].pathSplitter().join('/'), path[1..$]);
        else
            auto quoted = formatQuotedIfSpaces(path);

        archive.write(delimiter, ' ', quoted);
        writeProperties(attributes);
    }

    /// Writes the file attributes to the archive.
    void writeProperties(scope lazy Attributes attributes)
    {
        if (includeAttributes)
        {
            const attr = attributes;
            with (attr)
            {
                if (owner)
                    archive.write(" owner=", owner);

                if (permissions)
                {
                    version (Posix)
                    {
                        import core.sys.posix.sys.stat;
                        const value = permissions & ~S_IFMT;
                    }
                    else
                    {
                        const value = permissions;
                    }
                    archive.writef(" permissions=%04o", value);
                }
            }
        }
        archive.writeln();
    }

    /// Writes a header for an empty directory to the archive.
    void writeEmptyDirectoryHeader(scope string path, scope lazy Attributes attributes)
    {
        writeHeader(path, path[$-1] == '/' ? "" : "/", attributes);
    }

    /// Determines the attribues of the file denoted by `path`
    Attributes getAttributes(const string path)
    {
        if (!includeAttributes)
            return Attributes.init;

        DirEntry de = DirEntry(path);
        return getAttributes(de);
    }

    /// Determines the attribues of the file denoted by `de`
    Attributes getAttributes(scope ref DirEntry de)
    {
        if (!includeAttributes)
            return Attributes.init;

        Attributes res;
        res.permissions = de.attributes();
        res.owner = fileOwner(de);
        return res;
    }

    /// Determines the owner of the file/directory represented by `de`
    static string fileOwner(scope ref DirEntry de)
    {
        // FIXME: Upsream to Phobos?

        version (Posix)
        {
            import core.stdc.string;
            import core.sys.posix.pwd;

            const name = getpwuid(de.statBuf.st_uid).pw_name;
            const len = strlen(name);
            return cast(immutable) name[0 .. len];
        }
        else version (Windows)
        {
            // https://docs.microsoft.com/en-us/windows/win32/secauthz/finding-the-owner-of-a-file-object-in-c--

            import core.sys.windows.accctrl;
            import core.sys.windows.aclapi;
            import core.sys.windows.windows;
            import std.internal.cstring;

            void enforce(const bool check, const string component, const size_t line = __LINE__)
            {
                if (!check)
                {
                    const error = GetLastError();
                    const msg = format!"Failed to determine owner of `%s`: `%s` error %s"(de.name, component, error);
                    throw new HarException(msg, __FILE__, line);
                }
            }

            // Obtain a file / directory handle
            const cname = tempCString!TCHAR(de.name);
            auto handle = CreateFile(
                cname,
                GENERIC_READ,
                FILE_SHARE_VALID_FLAGS,
                null,
                OPEN_EXISTING,
                de.isDir ? FILE_FLAG_BACKUP_SEMANTICS : FILE_ATTRIBUTE_NORMAL,
                null,
            );
            enforce(handle != INVALID_HANDLE_VALUE, "CreateFile");

            // Get the owner SID of the file / directory.
            PSID pSidOwner = null;
            auto status = GetSecurityInfo(
                handle,
                SE_OBJECT_TYPE.SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION,
                &pSidOwner,
                null,
                null,
                null,
                null,
            );
            enforce(status == ERROR_SUCCESS, "GetSecurityInfo");

            // Determine the name / domain associated with the SID
            // Pass a static buffer to avoid the second call in most cases
            TCHAR[40] nameBuffer, domainBuffer;
            TCHAR[] name = nameBuffer;
            TCHAR[] domain = domainBuffer;

            DWORD nameLength = nameBuffer.length;
            DWORD domainLength = domainBuffer.length;
            SID_NAME_USE eUse = SID_NAME_USE.SidTypeUnknown;

            while (true)
            {
                status = LookupAccountSid(
                    null,                   // name of local or remote computer
                    pSidOwner,
                    name.ptr,
                    &nameLength,
                    domain.ptr,
                    &domainLength,
                    &eUse
                );

                if (status) // Sucessfully retrieved name/domain
                {
                    // Trim trailing null terminator
                    name = name[0 .. nameLength];
                    domain = domain[0 .. domainLength];
                    break;
                }

                enforce(GetLastError() == ERROR_INSUFFICIENT_BUFFER, "LookupAccountSid");
                name = new TCHAR[nameLength];
                domain = new TCHAR[domainLength];
            }

            static if (is(TCHAR == char))
            {
                if (name.ptr is nameBuffer.ptr)
                    return name.idup();
                else
                    return cast(immutable) name;
            }
            else
            {
                import std.conv : to;
                return to!string(name);
            }
        }
        else
            return null; // Not supported
    }

    /// Writes the content of the file denoted by `path` to the archive
    void includeFile(scope const string path, scope lazy Attributes attributes = Attributes.init)
    {
        import std.algorithm;

        writeHeader(path, attributes);

        auto content = File(path, "r").byChunk(2 << 12);
        bool hasNl;

        while (!content.empty)
        {
            const chunk = cast(char[]) content.front;
            hasNl = chunk.endsWith('\n');
            archive.write(chunk);
            content.popFront();
        }

        // Only add a newline if the file didn't end with one
        // See `Which Newlines belong to the file?` in the README
        if (!hasNl)
            archive.writeln();
    }
}
