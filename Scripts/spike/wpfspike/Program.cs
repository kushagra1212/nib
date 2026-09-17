using System.Windows;

namespace WpfSpike;

// Proves the Windows Desktop SDK restores and publishes off-Windows. Never run.
public static class Program
{
    [System.STAThread]
    public static void Main()
    {
        var app = new Application();
        app.Run(new Window { Title = "nib spike", Width = 320, Height = 120 });
    }
}
