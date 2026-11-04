// SPDX-License-Identifier: Apache-2.0
using Mono.Cecil;

// Rewrites an IL-only assembly as AnyCPU so CoreCLR on ARM64 will load it.
// Usage: cecilpatch <input.dll> <output.dll> [reference search dir...]
// Writing needs the referenced assemblies, e.g. to encode enum-typed default parameter values.
// Exit codes: 0 patched, 1 error, 2 already AnyCPU (nothing written).
if (args.Length < 2)
{
    Console.Error.WriteLine("Usage: cecilpatch <input.dll> <output.dll> [reference search dir...]");
    return 1;
}

var resolver = new DefaultAssemblyResolver();
foreach (var dir in args.Skip(2))
    resolver.AddSearchDirectory(dir);

static bool IsAnyCpu(ModuleDefinition m) =>
    m.Architecture == TargetArchitecture.I386
    && m.Attributes.HasFlag(ModuleAttributes.ILOnly)
    && !m.Attributes.HasFlag(ModuleAttributes.Required32Bit);

using (var module = ModuleDefinition.ReadModule(args[0], new ReaderParameters { AssemblyResolver = resolver }))
{
    Console.WriteLine($"before: Architecture={module.Architecture} Attributes={module.Attributes}");

    if (IsAnyCpu(module))
    {
        Console.WriteLine("already AnyCPU, nothing to do");
        return 2;
    }

    if (!module.Attributes.HasFlag(ModuleAttributes.ILOnly))
    {
        Console.Error.WriteLine("Refusing to patch: the module contains native code, so it really is architecture-specific");
        return 1;
    }

    module.Architecture = TargetArchitecture.I386;
    module.Attributes &= ~ModuleAttributes.Required32Bit;
    module.Attributes &= ~ModuleAttributes.Preferred32Bit;
    module.Write(args[1]);
}

// Read the result back rather than trusting the write
using (var written = ModuleDefinition.ReadModule(args[1]))
{
    Console.WriteLine($"after:  Architecture={written.Architecture} Attributes={written.Attributes}");
    if (!IsAnyCpu(written))
    {
        Console.Error.WriteLine("The written assembly is not AnyCPU");
        return 1;
    }
}

return 0;
