# 🎨 Figma 与 iOS 联动工作流

## 📋 目录

1. [设置 Figma 设计系统](#1-设置-figma-设计系统)
2. [导出资源到 Xcode](#2-导出资源到-xcode)
3. [同步设计令牌](#3-同步设计令牌)
4. [推荐的 Figma 插件](#4-推荐的-figma-插件)
5. [自动化工具](#5-自动化工具)
6. [协作流程](#6-协作流程)

---

## 1. 设置 Figma 设计系统

### 创建设计系统页面

在 Figma 中创建一个专门的 "Design System" 页面：

```
📁 Cheese App (Figma 项目)
├── 📄 Design System          ← 设计系统
│   ├── 🎨 Colors
│   ├── 📝 Typography
│   ├── 📏 Spacing
│   ├── 🔲 Radius
│   ├── 🌫 Shadows
│   └── 🧩 Components
├── 📄 Home
├── 📄 Rent
├── 📄 Profile
└── ...
```

### 颜色命名规范

```
品牌色:
├── Primary/Default    (#FFB92D) → DesignTokens.Brand.primary
├── Primary/Light      (#FFD580) → DesignTokens.Brand.primaryLight
├── Primary/Dark       (#CC9424) → DesignTokens.Brand.primaryDark
└── Secondary/Default  (#6B7280) → DesignTokens.Brand.secondary

语义色:
├── Success (#10B981)
├── Warning (#F59E0B)
├── Error   (#EF4444)
└── Info    (#3B82F6)

中性色:
├── Gray/50  (#F9FAFB)
├── Gray/100 (#F3F4F6)
├── ...
└── Gray/900 (#111827)
```

### 字体设置

建议使用系统字体以获得最佳性能：

| Figma 设置 | iOS 对应 |
|-----------|---------|
| SF Pro Display | `.system()` (默认) |
| SF Pro Text | `.system()` (默认) |
| Inter | 需要嵌入 |
| Ping Fang SC | `.system()` (中文自动) |

---

## 2. 导出资源到 Xcode

### 导出图片/图标

#### 步骤 1：Figma 设置导出

1. 选中元素
2. 右侧面板 → Design → Export
3. 点击 + 添加导出设置：

```
导出设置：
├── 1x  → PNG  (命名: icon_home)
├── 2x  → PNG  (命名: icon_home@2x)
└── 3x  → PNG  (命名: icon_home@3x)
```

#### 步骤 2：批量导出

使用快捷键或菜单：
- `Cmd + Shift + E` (Mac)
- File → Export

#### 步骤 3：导入 Xcode

1. 打开 `Assets.xcassets`
2. 右键 → Import...
3. 选择导出的文件

或者创建 Image Set：
1. 右键 → New Image Set
2. 命名为 `icon_home`
3. 拖入对应尺寸的图片

### 导出 SF Symbols 替代图标

优先使用 SF Symbols（无需导出）：

```swift
// 使用系统图标
Image(systemName: "house.fill")
Image(systemName: "car.fill")
Image(systemName: "person.3.fill")
```

查找图标：下载 [SF Symbols App](https://developer.apple.com/sf-symbols/)

---

## 3. 同步设计令牌

### 方法 A：手动同步（简单）

1. 从 Figma 复制颜色值
2. 更新 `DesignTokens.swift`

```swift
// DesignTokens.swift
enum Brand {
    // Figma: Primary/Default
    static let primary = Color(hex: "FFB92D")
}
```

### 方法 B：使用 Figma Tokens 插件（推荐）

1. 安装插件：[Figma Tokens](https://www.figma.com/community/plugin/843461159747178978)
2. 定义令牌
3. 导出为 JSON
4. 转换为 Swift

#### 导出的 JSON 格式：
```json
{
  "colors": {
    "primary": {
      "default": "#FFB92D",
      "light": "#FFD580",
      "dark": "#CC9424"
    }
  },
  "spacing": {
    "xs": "4",
    "sm": "8",
    "md": "16"
  }
}
```

#### 转换脚本（可选）

创建 `scripts/tokens-to-swift.js`：

```javascript
// 将 Figma Tokens JSON 转换为 Swift
const fs = require('fs');

const tokens = JSON.parse(fs.readFileSync('tokens.json'));

let swift = `// 自动生成 - 请勿手动编辑
import SwiftUI

enum DesignTokens {
`;

// 生成颜色
swift += `    enum Colors {\n`;
for (const [name, value] of Object.entries(tokens.colors)) {
    swift += `        static let ${name} = Color(hex: "${value}")\n`;
}
swift += `    }\n`;

swift += `}\n`;

fs.writeFileSync('DesignTokens.swift', swift);
console.log('✅ Generated DesignTokens.swift');
```

---

## 4. 推荐的 Figma 插件

### 必备插件

| 插件 | 用途 |
|-----|------|
| **[Figma Tokens](https://www.figma.com/community/plugin/843461159747178978)** | 管理设计令牌 |
| **[iOS Export Settings](https://www.figma.com/community/plugin/747228167548695118)** | 快速设置 iOS 导出 |
| **[Batch Export](https://www.figma.com/community/plugin/1067937725788498920)** | 批量导出资源 |

### 代码生成插件

| 插件 | 功能 |
|-----|------|
| **[Figma to SwiftUI](https://www.figma.com/community/plugin/1159123024924461424)** | 生成 SwiftUI 代码 |
| **[Locofy](https://www.locofy.ai/)** | AI 生成前端代码 |

### 使用 Figma to SwiftUI 插件

1. 安装插件
2. 选中组件
3. 右键 → Plugins → Figma to SwiftUI
4. 复制生成的代码

⚠️ 注意：生成的代码通常需要手动优化

---

## 5. 自动化工具

### 选项 1：使用 Figma API

```bash
# 获取文件信息
curl -H "X-Figma-Token: YOUR_TOKEN" \
  "https://api.figma.com/v1/files/FILE_KEY"
```

### 选项 2：使用 Style Dictionary

[Style Dictionary](https://amzn.github.io/style-dictionary/) 可以将设计令牌转换为多平台代码。

```bash
npm install -g style-dictionary
```

配置 `config.json`：
```json
{
  "source": ["tokens/**/*.json"],
  "platforms": {
    "ios-swift": {
      "transformGroup": "ios-swift",
      "buildPath": "CheeseApp/CheeseApp/Shared/Theme/",
      "files": [{
        "destination": "GeneratedTokens.swift",
        "format": "ios-swift/class.swift"
      }]
    }
  }
}
```

运行：
```bash
style-dictionary build
```

---

## 6. 协作流程

### 推荐的工作流

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  设计师     │────▶│   Figma     │────▶│   开发者    │
│  (Design)   │     │  (Source)   │     │   (Code)    │
└─────────────┘     └─────────────┘     └─────────────┘
      │                   │                   │
      │                   │                   │
      ▼                   ▼                   ▼
 创建设计           更新设计令牌         更新代码
 定义组件           导出资源             实现功能
                   标注切图             测试 UI
```

### 设计交接清单

设计师完成设计后提供：

- [ ] **设计文件链接** (Figma)
- [ ] **设计令牌** (颜色、字体、间距)
- [ ] **切图资源** (1x, 2x, 3x)
- [ ] **交互说明** (状态、动画)
- [ ] **标注文档** (间距、尺寸)

### 使用 Figma 的开发者模式

1. 打开 Figma 文件
2. 右上角切换到 "Dev Mode"（需要付费版）
3. 查看：
   - 元素尺寸和间距
   - 颜色值
   - 字体信息
   - CSS/SwiftUI 代码片段

---

## 📁 项目文件对应关系

```
Figma 设计系统              →    Xcode 代码
───────────────────────────────────────────
Design System / Colors      →    DesignTokens.swift
Design System / Typography  →    DesignTokens.swift
Design System / Spacing     →    DesignTokens.swift
Design System / Components  →    Shared/Components/
───────────────────────────────────────────
Assets / Icons              →    Assets.xcassets/
Assets / Images             →    Assets.xcassets/
Assets / App Icon           →    Assets.xcassets/AppIcon
───────────────────────────────────────────
Screens / Login             →    Features/Profile/Views/AuthView.swift
Screens / Home              →    Features/Rent/Views/RentListView.swift
Screens / Profile           →    Features/Profile/Views/ProfileView.swift
```

---

## ✅ 最佳实践

### Do's ✅

1. **使用设计令牌** - 不要硬编码颜色和尺寸
2. **组件化** - Figma 组件对应 SwiftUI 组件
3. **命名一致** - Figma 和代码使用相同命名
4. **版本记录** - 记录每次同步的日期
5. **使用 SF Symbols** - 优先使用系统图标

### Don'ts ❌

1. **不要直接复制生成的代码** - 需要优化
2. **不要忽略深色模式** - 同时导出两套颜色
3. **不要用截图代替切图** - 影响清晰度
4. **不要跳过设计审核** - 确保实现与设计一致

---

## 🔗 有用的资源

- [Figma Developer Docs](https://www.figma.com/developers)
- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [SF Symbols](https://developer.apple.com/sf-symbols/)
- [SwiftUI Documentation](https://developer.apple.com/documentation/swiftui/)

---

Happy Designing! 🎨🧀

