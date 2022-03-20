import std.array;
import std.algorithm;
import std.exception;
import std.range;
import std.path;
import std.file;
import std.stdio;

import std.format : format;
import std.process;

class SilentException : Exception
{
    this()
    {
        super(null);
    }
}

auto quit()
{
    return new SilentException();
}

int main(string[] args)
{
    try
    {
        return tryMain(args);
    }
    catch (SilentException)
    {
        return 1;
    }
}

int tryMain(string[] args)
{
    // TODO: move to std.path
    version (Windows)
        string exeExtention = ".exe";
    else
        string exeExtention;

    const rootDir = __FILE_FULL_PATH__.dirName.dirName.dirName;
    const testDir = buildPath(rootDir, "test", "cli");
    const outDir = rootDir.buildPath("out", "test", "cli");
    const harExe = rootDir.buildPath("out", "har" ~ exeExtention);

    if (const status = runExtractionTests(testDir, outDir, harExe))
        return status;

    if (const status = runCompressionTests(testDir, outDir, harExe))
        return status;

    return 0;
}

int runExtractionTests(const string testBaseDir, const string outBaseDir, const string harExe)
{
    const testDir = testBaseDir.buildPath("extraction");
    const outTestDir = outBaseDir.buildPath("extraction");
    mkdirRecurse(outTestDir);

    foreach (entry; dirEntries(testDir, "*.har", SpanMode.shallow))
    {
        auto file = entry.name;
        auto name = file.baseName.setExtension(".expected");
        run(format("%s %s --dir=%s", harExe, file, outTestDir.buildPath(name)));
        auto expected = file.setExtension(".expected");
        auto actual = outTestDir.buildPath(name);
        run(format("diff --brief -r %s %s", expected, actual));
    }
    return 0;
}

int runCompressionTests(const string testBaseDir, const string outBaseDir, const string harExe)
{
    const testDir = testBaseDir.buildPath("compression");
    const outTestDir = outBaseDir.buildPath("compression");
    mkdirRecurse(outTestDir);

    // Workaround because git cannot track empty directories
    const addedEmptyDir = buildPath(testDir, "empty_directory", "empty");
    mkdirRecurse(addedEmptyDir);

    // Generate custom properties tests
    // Cannot track these in git because ownership / permission is a hassle for several file systems
    version (Windows) {} else
    {
        import core.stdc.string;
        import core.sys.posix.pwd;
        // import core.sys.posix.sys.stat;
        import std.conv;

        const ownerPtr = getpwuid(DirEntry(addedEmptyDir).statBuf.st_uid).pw_name;
        const owner = ownerPtr[0 .. strlen(ownerPtr)];

        const fileProperties = buildPath(testDir, "fileProperties");
        scope (success) rmdirRecurse(fileProperties);
        {
            const file = buildPath(fileProperties, "file.txt");
            mkdirRecurse(fileProperties);
            std.file.write(file, "Hello, World");
            setAttributes(file, octal!625);

            File expected = File(buildPath(fileProperties, "expected.har"), "w");
            expected.writefln(`--- file.txt owner=%s permissions=%04o`, owner, getAttributes(file));
            expected.writeln("Hello, World");

            std.file.write(buildPath(fileProperties, "extra-args"), "--attributes");
        }

        const dirProperties = buildPath(testDir, "dirProperties");
        scope (success) rmdirRecurse(dirProperties);
        {
            const emptyDir = buildPath(dirProperties, "empty");
            mkdirRecurse(emptyDir);
            setAttributes(emptyDir, octal!750);

            File expected = File(buildPath(dirProperties, "expected.har"), "w");
            expected.writefln(`--- empty/ owner=%s permissions=%04o`, owner, getAttributes(emptyDir));

            std.file.write(buildPath(dirProperties, "extra-args"), "--attributes");
        }
    }

    foreach (test; dirEntries(testDir, SpanMode.shallow))
    {
        if (!test.isDir)
        {
            writeln("Ignoring unexpected file: ", test.name);
            continue;
        }

        writeln("\n--------------------------------------------------------------------------------");
        writeln("Test: ", test.name);

        const expectedPath = buildPath(test.name, "expected.har");
        if (!exists(expectedPath))
        {
            writeln("Expected output file: ", expectedPath);
            throw quit;
        }

        const outputPath = buildPath(outTestDir, baseName(test.name)).setExtension(".har");

        string[] args;
        const extraArgs = buildPath(test.name, "extra-args");
        const cmdOverride = buildPath(test.name, "cmdline");

        if (exists(cmdOverride))
        {
            enforce(!exists(extraArgs), "Cannot use `extra-args` with explicit `cmdline`!");
            args = readText(cmdOverride).split();
        }
        else
        {
            args = dirEntries(test.name, SpanMode.shallow)
                        .map!(f => f.name)
                        .filter!(f => !f.among(expectedPath, cmdOverride, extraArgs))
                        .map!(f => f.relativePath(test))
                        .array;

            if (exists(extraArgs))
                args ~= readText(extraArgs).split();
        }

        runProcess(harExe ~ args, File(outputPath, "w"), test.name);
        if (tryRunProcess([ "git", "diff", "--no-index", "--ignore-space-at-eol", "--exit-code", expectedPath, outputPath ]))
        {
            if (environment.get("AUTO_UPDATE", "0") == "1")
            {
                writeln("=> Updating ", expectedPath);
                std.file.write(expectedPath, readText(outputPath));
            }
            else
                throw quit();
        }
    }
    return 0;
}

void run(string command)
{
    writefln("[SHELL] %s", command);
    stdout.flush();
    auto pid = spawnShell(command);
    auto exitCode = wait(pid);
    writeln("--------------------------------------------------------------------------------");
    if (exitCode != 0)
    {
        writefln("last command exited with code %s", exitCode);
        throw quit;
    }
}

void runProcess(scope const string[] cmd, File output = stdout, const string cwd = getcwd())
{
    if (tryRunProcess(cmd, output, cwd))
        throw quit;
}

int tryRunProcess(scope const string[] cmd, File output = stdout, const string cwd = getcwd())
{
    writefln(`[PROC] %-("%s" %)`, cmd);
    stdout.flush();
    auto pid = spawnProcess(cmd, stdin, output, stderr, null, Config.none, cwd);
    const exitCode = wait(pid);
    if (exitCode != 0)
        writeln("Last command failed with status ", exitCode);
    return exitCode;
}
