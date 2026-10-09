using System;
using System.Collections.Generic;
using System.Windows.Automation;
using Translator.Windows;

class PlainTextContentTest
{
    class Node
    {
        internal ControlType Type;
        internal bool Focusable;
        internal List<Node> Children = new List<Node>();
        internal Node(ControlType type, params Node[] children) { Type = type; Children.AddRange(children); }
    }
    static bool Supported(params Node[] roots)
    {
        return PlainTextContent.IsSupported(roots, node => node.Type, node => node.Focusable, node => node.Children);
    }
    static void Check(bool valid, string label)
    {
        if (!valid) throw new InvalidOperationException(label);
        Console.WriteLine("PASS: " + label);
    }
    static int Main()
    {
        try {
            Check(Supported(), "empty drafts remain supported");
            Check(Supported(new Node(ControlType.Text)), "ordinary text remains supported");
            Check(Supported(new Node(ControlType.Group, new Node(ControlType.Text)), new Node(ControlType.Group)),
                "pasted paragraphs and empty lines are accepted");
            Check(Supported(new Node(ControlType.List,
                new Node(ControlType.ListItem, new Node(ControlType.Text)),
                new Node(ControlType.ListItem, new Node(ControlType.Group, new Node(ControlType.Text))),
                new Node(ControlType.List, new Node(ControlType.ListItem, new Node(ControlType.Text))))),
                "pasted text lists and nested lists are accepted");
            foreach (var kind in new[] { ControlType.Image, ControlType.Button, ControlType.Edit, ControlType.Hyperlink }) {
                Check(!Supported(new Node(ControlType.List, new Node(ControlType.ListItem, new Node(kind)))),
                    "embedded " + kind.ProgrammaticName + " remains protected");
            }
            var widget = new Node(ControlType.List, new Node(ControlType.ListItem)); widget.Focusable = true;
            Check(!Supported(widget), "an interactive list widget is rejected");
            Check(!Supported(new Node(ControlType.Text, new Node(ControlType.Image))),
                "embedded objects inside text nodes are also rejected");
            var large = new List<Node>();
            for (int i = 0; i < 301; i++) large.Add(new Node(ControlType.Text));
            Check(!Supported(large.ToArray()), "large trees stop at the traversal limit");
            var deep = new Node(ControlType.Text);
            for (int i = 0; i < 34; i++) deep = new Node(ControlType.Group, deep);
            Check(!Supported(deep), "deep trees stop at the traversal limit");
            return 0;
        } catch (Exception error) { Console.Error.WriteLine("FAIL: " + error.Message); return 1; }
    }
}
