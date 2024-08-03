const builtin = @import("builtin");
const std = @import("std");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
};

const PySrc = struct {
    py_name: []const u8,
    dir: []const u8,

    fn fullPath(self: PySrc, allocator: std.mem.Allocator) []const u8 {
        return join(allocator, &.{ self.dir, self.py_name });
    }
    fn getModuleName(self: PySrc) []const u8 {
        return std.mem.trimRight(u8, self.py_name, ".py");
    }
    fn getCPath(self: PySrc, allocator: std.mem.Allocator) []const u8 {
        return join(allocator, &.{ self.dir, self.getModuleName(), ".c" });
    }
};

test "Check PySrc Outputs" {
    // var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    // defer arena.deinit();
    // const allocator = arena.allocator();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const py_name = "test.py";
    const dir = "./test/";
    const p = PySrc{ .py_name = py_name, .dir = dir };

    const full_path = p.fullPath(allocator);
    defer allocator.free(full_path);
    try std.testing.expectEqualStrings("./test/test.py", full_path);

    const module_name = p.getModuleName();
    try std.testing.expectEqualStrings("test", module_name);

    const c_path = p.getCPath(allocator);
    defer allocator.free(c_path);
    try std.testing.expectEqualStrings("./test/test.c", c_path);
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const python_exe = b.option([]const u8, "python-exe", "Python executable to use") orelse "python";
    const cythonize_exe = b.option([]const u8, "cythonize-exe", "Cythonize executable to use") orelse "cythonize";
    const pythonInc = getPythonIncludePath(python_exe, b.allocator) catch @panic("Missing python");
    var dir = try std.fs.cwd().openDir("./py_src", .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    var files_array = std.ArrayList(PySrc).init(b.allocator);
    defer files_array.deinit();

    while (try iter.next()) |entry| {
        if (entry.kind == .file) {
            if (std.mem.endsWith(u8, entry.name, ".py")) {
                const py_file = PySrc{ .py_name = entry.name, .dir = "./py_src/" };
                try files_array.append(py_file);
            }
        }
    }

    const cythonize = b.addSystemCommand(&.{cythonize_exe});
    for (files_array.items) |file| {
        cythonize.addArg(file.fullPath(b.allocator));
    }

    for (targets) |t| {
        const target_path = try t.zigTriple(b.allocator);
        for (files_array.items) |file| {
            const so = b.addSharedLibrary(.{
                .name = file.getModuleName(),
                .target = target,
                .optimize = .ReleaseSafe,
            });
            so.addCSourceFile(.{ .file = b.path(file.getCPath(b.allocator)) });
            so.linkLibC();
            so.addIncludePath(.{ .cwd_relative = pythonInc });
            so.step.dependOn(&cythonize.step);
            const target_output = b.addInstallArtifact(
                so,
                .{
                    .dest_dir = .{
                        .override = .{
                            .custom = target_path,
                        },
                    },
                },
            );
            b.getInstallStep().dependOn(&target_output.step);
        }
    }
}

fn getPythonIncludePath(
    python_exe: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const includeResult = try runProcess(.{
        .allocator = allocator,
        .argv = &.{ python_exe, "-c", "import sysconfig; print(sysconfig.get_path('include'), end='')" },
    });
    defer allocator.free(includeResult.stderr);
    return includeResult.stdout;
}

fn join(allocator: std.mem.Allocator, strs: []const []const u8) []const u8 {
    return std.mem.join(allocator, "", strs) catch @panic("Failed to allocate memory");
}

const runProcess = std.process.Child.run;
