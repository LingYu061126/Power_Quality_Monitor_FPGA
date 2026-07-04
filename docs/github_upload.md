# GitHub 上传说明

本文档说明如何把当前项目整理后上传到 GitHub。

## 1. 上传前检查

建议上传：

- `power_quality_monitor/`
- `wifi_monitor/`
- `Game/`
- `docs/`
- `README.md`
- `.gitignore`
- `.gitattributes`
- `LICENSE`

默认不上传：

- Quartus 生成目录：`db/`、`incremental_db/`、`output_files/`
- ModelSim 生成目录：`work/`、`transcript`、`*.wlf`
- 编程文件：`*.sof`、`*.pof`
- 运行数据：`*.csv`、`*.db`
- 实验指导书、截图、报告备份、临时格式处理脚本

如确实要分享 `.sof/.pof`，建议在 GitHub Release 中上传，而不是提交到主分支。

## 2. 初始化 Git

当前工作目录中可能存在一个空的 `.git` 目录。如果 `git status` 提示不是 Git 仓库，或者 `git init` 报错，可以先检查：

```bash
cd /run/media/chidan/新加卷/lab
ls -la .git
```

如果 `.git` 是空目录且没有 `HEAD` 文件，可以重命名它：

```bash
mv .git .git_empty_backup
```

然后初始化：

```bash
git init -b main
git status
```

## 3. 查看将要提交的文件

先不要急着提交，检查忽略规则是否生效：

```bash
git status --short
```

如果看到 `db/`、`output_files/`、`.csv`、`.db`、`.docx`、`.pdf` 等文件出现在待提交列表中，先不要提交，继续调整 `.gitignore`。

也可以检查被忽略文件：

```bash
git status --ignored --short
```

## 4. 首次提交

```bash
git add README.md .gitignore .gitattributes LICENSE docs power_quality_monitor wifi_monitor Game
git status --short
git commit -m "Initial commit: FPGA power quality monitor"
```

如果你只想上传电能质量项目和 WiFi 程序，不上传 `Game/`，把最后一条 `git add` 中的 `Game` 去掉。

## 5. 创建 GitHub 仓库

在 GitHub 网页中新建仓库，例如：

```text
fpga-power-quality-monitor
```

建议：

- 不勾选自动生成 README。
- 不勾选自动生成 `.gitignore`。
- License 可以不选，因为本地已有 `LICENSE`。

## 6. 绑定远程并推送

HTTPS 方式：

```bash
git remote add origin https://github.com/你的用户名/fpga-power-quality-monitor.git
git push -u origin main
```

SSH 方式：

```bash
git remote add origin git@github.com:你的用户名/fpga-power-quality-monitor.git
git push -u origin main
```

如果 GitHub 要求登录，按提示使用浏览器授权或 Personal Access Token。

## 7. 后续更新

修改代码后：

```bash
git status
git add 需要提交的文件
git commit -m "Describe the change"
git push
```

建议每次提交前运行：

```bash
cd wifi_monitor
python3 -m unittest -v test_monitor.py
```

Quartus 工程修改后，建议重新编译确认 0 error。
