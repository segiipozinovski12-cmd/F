using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Animation;

namespace VO1D.Desktop;

public partial class BrandMark : UserControl
{
    public BrandMark()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            var a = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(20))
            {
                RepeatBehavior = RepeatBehavior.Forever
            };
            var b = new DoubleAnimation(0, -360, TimeSpan.FromSeconds(24))
            {
                RepeatBehavior = RepeatBehavior.Forever
            };
            ArcRotate1.BeginAnimation(System.Windows.Media.RotateTransform.AngleProperty, a);
            ArcRotate2.BeginAnimation(System.Windows.Media.RotateTransform.AngleProperty, b);
        };
    }
}