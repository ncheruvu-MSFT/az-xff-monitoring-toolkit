<%@ Page Language="C#" AutoEventWireup="true" CodeBehind="Reports.aspx.cs" Inherits="XffDemo.Net47.ReportsPage" %>
<!DOCTYPE html>
<html>
<head runat="server">
    <title>XFF Reports (.NET 4.7)</title>
    <style>
        body { font-family: Segoe UI, Arial, sans-serif; margin: 2em; color: #222; }
        h1 { color: #0078d4; }
        table { border-collapse: collapse; margin-top: 1em; width: 100%; font-size: 12px; }
        th, td { padding: 4px 8px; border: 1px solid #ddd; text-align: left; vertical-align: top; }
        th { background: #f3f3f3; position: sticky; top: 0; }
        tr:nth-child(even) { background: #fafafa; }
        .summary { display: flex; gap: 2em; margin: 1em 0; }
        .card { padding: 1em; background: #f8f9fa; border-left: 4px solid #0078d4; }
        .card .num { font-size: 2em; font-weight: bold; color: #0078d4; }
        .nav a { margin-right: 1em; }
        .actions { margin: 1em 0; }
    </style>
</head>
<body>
    <form id="form1" runat="server">
        <h1>XFF Capture Report</h1>
        <div class="nav">
            <a href="Default.aspx">Home</a>
            <a href="Reports.aspx">Reports</a>
            <a href="Reports.aspx?format=csv">Download CSV</a>
            <a href="Reports.aspx?format=json">Download JSON</a>
        </div>
        <div class="summary">
            <div class="card">
                <div>Total Requests (since app start)</div>
                <div class="num"><asp:Literal ID="LitTotal" runat="server" /></div>
            </div>
            <div class="card">
                <div>Unique Resolved Client IPs (last <asp:Literal ID="LitBufferSize" runat="server" />)</div>
                <div class="num"><asp:Literal ID="LitUnique" runat="server" /></div>
            </div>
            <div class="card">
                <div>Requests with XFF Header</div>
                <div class="num"><asp:Literal ID="LitWithXff" runat="server" /></div>
            </div>
        </div>
        <div class="actions">
            <asp:Button ID="BtnClear" runat="server" Text="Clear Buffer" OnClick="BtnClear_Click" OnClientClick="return confirm('Clear in-memory buffer?');" />
        </div>
        <h2>Top Resolved Client IPs</h2>
        <asp:Literal ID="LitTopIps" runat="server" />
        <h2>Recent Requests</h2>
        <asp:Literal ID="LitEntries" runat="server" />
        <p style="margin-top:2em;font-size:11px;color:#666">
            This page reads from an in-memory buffer (max 500 entries). For durable reporting use the KQL queries in
            <code>queries/xff-custom-dimensions.kql</code> against Application Insights.
        </p>
    </form>
</body>
</html>
