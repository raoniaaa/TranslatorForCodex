using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

// Generate the Windows SDK COM declarations from the installed OS type library.
// No downloaded interop DLL or .NET SDK is needed to build this prototype.
class ImportAutomation : ITypeLibImporterNotifySink
{
    [DllImport("oleaut32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void LoadTypeLibEx(string file, int kind, out ITypeLib library);
    public void ReportEvent(ImporterEventKind kind, int code, string message) { }
    public Assembly ResolveRef(object library) { throw new NotSupportedException("Unexpected type library dependency."); }
    static void Main(string[] args)
    {
        ITypeLib library;
        LoadTypeLibEx(Path.Combine(Environment.SystemDirectory, "UIAutomationCore.dll"), 2, out library);
        string output = Path.GetFullPath(args[0]);
        Directory.SetCurrentDirectory(Path.GetDirectoryName(output));
        var assembly = new TypeLibConverter().ConvertTypeLibToAssembly(library, Path.GetFileName(output),
            TypeLibImporterFlags.None, new ImportAutomation(), null, null, "NativeAutomation", null);
        assembly.Save(Path.GetFileName(output));
    }
}
