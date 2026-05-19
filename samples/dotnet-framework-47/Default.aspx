<%@ Page Language="C#" AutoEventWireup="true" CodeBehind="Default.aspx.cs" Inherits="XffDemo.Net47.DefaultPage" %>
<!DOCTYPE html>
<html>
<head runat="server">
    <title>XFF Demo (.NET 4.7)</title>
    <style>
        body { font-family: Segoe UI, Arial, sans-serif; margin: 2em; color: #222; }
        h1 { color: #0078d4; }
        table { border-collapse: collapse; margin-top: 1em; }
        th, td { padding: 6px 12px; border: 1px solid #ddd; text-align: left; }
        th { background: #f3f3f3; }
        code { background: #f3f3f3; padding: 1px 4px; border-radius: 3px; }
        .nav a { margin-right: 1em; }
    </style>
</head>
<body>
    <h1>X-Forwarded-For Demo &mdash; .NET Framework 4.7</h1>
    <div class="nav">
        <a href="Default.aspx">Home</a>
        <a href="Reports.aspx">Reports</a>
    </div>
    <p>This request was captured by <code>XffHttpModule</code> and sent to Application Insights as custom dimensions.</p>
    <h2>Current Request</h2>
    <asp:Literal ID="LitEntry" runat="server" />
    <h2>All Request Headers</h2>
    <asp:Literal ID="LitHeaders" runat="server" />
</body>
</html>
