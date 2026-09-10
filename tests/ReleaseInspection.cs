using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

public static class ScomReleaseInspection
{
    private delegate bool ResourceNameCallback(IntPtr module, IntPtr type, IntPtr name, IntPtr parameter);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumResourceNames(IntPtr module, IntPtr type, ResourceNameCallback callback, IntPtr parameter);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LockResource(IntPtr resource);

    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    private static extern uint MsiOpenDatabase(string path, IntPtr persist, out uint database);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    private static extern uint MsiDatabaseOpenView(uint database, string query, out uint view);
    [DllImport("msi.dll")]
    private static extern uint MsiCreateRecord(uint fieldCount);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    private static extern uint MsiRecordSetString(uint record, uint field, string value);
    [DllImport("msi.dll")]
    private static extern uint MsiViewExecute(uint view, uint record);
    [DllImport("msi.dll")]
    private static extern uint MsiViewFetch(uint view, out uint record);
    [DllImport("msi.dll")]
    private static extern uint MsiRecordReadStream(uint record, uint field, byte[] buffer, ref uint count);
    [DllImport("msi.dll")]
    private static extern uint MsiCloseHandle(uint handle);

    public static Dictionary<string, byte[]> ReadResources(string path, int resourceType)
    {
        IntPtr module = LoadLibraryEx(path, IntPtr.Zero, 0x22);
        if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            Dictionary<string, byte[]> resources = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            ResourceNameCallback callback = delegate(IntPtr currentModule, IntPtr type, IntPtr name, IntPtr parameter)
            {
                IntPtr resource = FindResource(currentModule, name, type);
                if (resource == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                uint length = SizeofResource(currentModule, resource);
                IntPtr data = LockResource(LoadResource(currentModule, resource));
                if (data == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                byte[] bytes = new byte[checked((int)length)];
                Marshal.Copy(data, bytes, 0, bytes.Length);
                string key = name.ToInt64() <= ushort.MaxValue ? "#" + name.ToInt64() : Marshal.PtrToStringUni(name);
                resources.Add(key, bytes);
                return true;
            };
            if (!EnumResourceNames(module, new IntPtr(resourceType), callback, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            GC.KeepAlive(callback);
            return resources;
        }
        finally { FreeLibrary(module); }
    }

    private static void CheckMsi(uint status)
    {
        if (status != 0) throw new Win32Exception((int)status);
    }

    public static byte[] ReadInstallerCabinet(string path)
    {
        return ReadInstallerStream(path, "SELECT `Data` FROM `_Streams` WHERE `Name` = 'product.cab'", null);
    }

    public static byte[] ReadInstallerIcon(string path, string iconName)
    {
        if (String.IsNullOrEmpty(iconName)) throw new ArgumentException("An icon name is required.", "iconName");
        return ReadInstallerStream(path, "SELECT `Data` FROM `Icon` WHERE `Name` = ?", iconName);
    }

    private static byte[] ReadInstallerStream(string path, string query, string parameterValue)
    {
        uint database = 0;
        uint view = 0;
        uint record = 0;
        uint parameterRecord = 0;
        try
        {
            CheckMsi(MsiOpenDatabase(path, IntPtr.Zero, out database));
            CheckMsi(MsiDatabaseOpenView(database, query, out view));
            if (parameterValue != null)
            {
                parameterRecord = MsiCreateRecord(1);
                if (parameterRecord == 0) throw new InvalidOperationException("Cannot create an MSI query parameter record.");
                CheckMsi(MsiRecordSetString(parameterRecord, 1, parameterValue));
            }
            CheckMsi(MsiViewExecute(view, parameterRecord));
            CheckMsi(MsiViewFetch(view, out record));
            using (MemoryStream stream = new MemoryStream())
            {
                byte[] buffer = new byte[65536];
                uint count;
                do
                {
                    count = (uint)buffer.Length;
                    CheckMsi(MsiRecordReadStream(record, 1, buffer, ref count));
                    stream.Write(buffer, 0, (int)count);
                } while (count != 0);
                return stream.ToArray();
            }
        }
        finally
        {
            if (record != 0) MsiCloseHandle(record);
            if (parameterRecord != 0) MsiCloseHandle(parameterRecord);
            if (view != 0) MsiCloseHandle(view);
            if (database != 0) MsiCloseHandle(database);
        }
    }
}