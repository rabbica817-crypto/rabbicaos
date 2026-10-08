// RabbicaOS 安装幻灯片 (slideshowAPIVersion: 2, 纯 QtQuick 无外部依赖)
// 依据: Calamares branding 文档 — show.qml 为幻灯片根组件, API 2 允许任意 QML
import QtQuick 2.15

Rectangle {
    id: root
    color: "#3b2b20"

    // 轮换页
    property int page: 0
    readonly property var pages: [
        { "t": "欢迎使用 RabbicaOS", "s": "一杯咖啡的时间，装好你的开发利器" },
        { "t": "Debian 13 稳固底座", "s": "内核 6.12 LTS · Qt 6.8 · KF6 6.13" },
        { "t": "KOS 桌面 Shell", "s": "Dock · 顶栏 · 启动器 · 通知中心 · 液态玻璃" },
        { "t": "开箱即用", "s": "微信 · QQ · 钉钉 · WPS · 中文输入法 已就绪" }
    ]

    Timer {
        interval: 5000; running: true; repeat: true
        onTriggered: root.page = (root.page + 1) % root.pages.length
    }

    Image {
        source: "logo.png"
        anchors { left: parent.left; leftMargin: 120; verticalCenter: parent.verticalCenter }
        width: 260; height: 260
        fillMode: Image.PreserveAspectFit
    }

    Text {
        id: title
        text: root.pages[root.page].t
        anchors { left: parent.left; leftMargin: 460; top: parent.top; topMargin: 170 }
        color: "#f5efe6"; font.pixelSize: 52; font.bold: true
    }
    Text {
        text: root.pages[root.page].s
        anchors { left: title.left; top: title.bottom; topMargin: 24 }
        color: "#c98a4b"; font.pixelSize: 30
    }
}
