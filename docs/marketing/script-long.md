# Lucet 光集 · 长版口播稿（中文 + English）

适合：B 站 / 视频号 / 小红书长视频 / YouTube，真人出镜 + 录屏穿插。
时长：中文约 5 分钟（按每秒 4–5 个字），英文约 6 分钟（每分钟约 140 词）。`【…】` 里你自己的话不计在内。想剪短，先删第 2 段的滑块列举和第 5 段的功能细节，故事线不受影响。

怎么用：

- **提词器**：`docs/marketing/xiaohongshu/teleprompter.html?v=long-zh`（中文）或 `?v=long-en`（英文），用 Chrome 打开。空格开始，↑↓ 调速度，M 镜像。不加参数还是原来的 55 秒短版。
- **`【…】` 是留给你的**：只有你能说的话（你当时的感受、你拍的地方）。这几句最能让人相信你，请一定换成你自己的话；不想说就整句删掉，前后照样接得上。
- **画面建议**写在每段后面的方括号里，录完在剪映里按段落插录屏。
- 稿子里的事实都来自项目记录（提交历史、实测数字、我们的对话）。**别加没发生的事**，也别说价格、「免费」「收费」，别暗示和 DJI 有合作。
- 稿子里提到了张小样，作为「边调边学」的灵感来源。这是诚实的致谢；如果你不想提他的名字，把那句换成「抖音上有摄影博主……」即可。

---

## 中文版

### 1. 开场（约 10 秒）

我拍了一段很喜欢的素材。
回到家，想在 Mac 的大屏幕上，把颜色调一调。
然后我发现了一件很奇怪的事。

〔画面：你自己的 DJI 航拍或风景，2–3 秒，不加字。然后切到你对着镜头。〕

### 2. 我遇到的问题（约 30 秒）

DJI 的调色 App，Mimo，只有手机版。
想在大屏幕上调，就得把素材传回手机，在一块小小的屏幕上，一点一点地抠。

那就用专业软件吧。
Lightroom、Photoshop 当然什么都能做，
可是第一次打开，迎面就是几十个滑块。
曝光、高光、阴影、白色、黑色、去朦胧……
我不知道先动哪一个，也不知道动完，到底是变好了还是变坏了。

【这里说一句你当时的真实感受，比如：那一刻我只想把照片调好看，并不想先上一门课。】

〔画面：手机上的小屏调色；再切到一屏密密麻麻的滑块（可以是模糊处理过的截图，不要出现别家软件的大 logo）。〕

### 3. 所以我决定自己做一个（约 45 秒）

所以我想：能不能有一个工具，
在 Mac 上，简单得像手机 App；
想学的时候，又有人在旁边，把道理讲给你听？

最早的一版原型，是 ChatGPT 帮我写的。它能跑，但又慢、又乱。
后来我把它交给 Claude Code，第一件事不是加功能，而是挑毛病，而且每个毛病都在我的 Mac 上实测：

一个有两千个文件的文件夹，原来加进素材库要将近 7 秒，界面直接卡住；现在，不到一百分之一秒。
DJI Pocket 3 官方的 LUT，原来根本导不进来，因为文件里的标题是另一种中文编码；现在，能正常用了。

〔画面：GitHub 上第一条提交「Baseline: ChatGPT prototype as received」；然后是一个大文件夹拖进 Lucet 光集，瞬间出现缩略图。〕

### 4. 一句人话，一次修改（约 40 秒）

做的过程里，最让我意外的是：
几乎每一次改动，都是从我的一句普通的话开始的。

「这个蓝色太亮了。」
「右边太松了，不够紧凑。」
「信息不够。」
「方框太多了。」

我说一句，AI 改一版，我再看，再说。一轮一轮。

当然，AI 也会错，而且错得很像回事。
有一张白桌子上的拿铁，它说这张照片「整体偏亮」，建议我把曝光降一档半。
可是白桌子，本来就应该是亮的呀。
这种错，只有你真的去用、真的去看，才会发现。发现了，就改掉，再加上测试，保证它不会再犯。

【这里可以说一句你对「和 AI 一起做东西」的体会，比如：它很快，但哪里好看、哪里不对，还是得我来拍板。】

〔画面：几张真实的前后对比截图（蓝色太亮→中性灰、方框→扁平网页）；拿铁照片和那句错误的提示。〕

### 5. 它现在能做什么（约 55 秒）

那它现在能做什么呢？我直接给你看。

导入一个文件夹，或者直接把照片拖进窗口。
点一下「自动」，它会先读这张照片，再替你调好明暗和颜色。
它很克制：白底的照片保持明亮，夜景还是夜景，日落的暖色会留下来。不满意，按一下撤销就回去了。

想自己调，默认只有六个滑块：亮度、对比度、亮部、暗部、冷暖、鲜艳度。每一个，都有一句人话告诉你它是干什么的。

预设，不是一排看不懂的名字，而是直接用你这张照片做成的小图，喜欢哪个，点哪个。
裁剪，就直接在照片上拖。

调完，直接存进 Mac 的「照片」。开着 iCloud，你的 iPhone 上马上就能看到。
视频，还能剪成三秒以内，做成真正的实况照片。

〔画面：全程真实录屏。自动前后对比按 `\` 来回切；点预设缩略图；拖裁剪框；最后拿出 iPhone，相册里出现刚调好的照片。〕

### 6. 边调边学（约 55 秒）

但我最想做好的，其实是另一件事。

一键滤镜能让照片变好看，可是下一次，你还是不知道为什么。

抖音上有一位摄影博主，张小样，他用动画讲直方图、讲曲线、讲光圈，比任何说明书都清楚。
可惜，他只有几条视频，讲不完所有的基础。

所以，我们把这种讲法，放进了 App 里。
用你自己的照片：看它怎样碎成一个个像素，再按亮度堆成一座小山，那就是直方图；
拖一拖光圈，看背景怎样慢慢变虚；
拖一下「亮部」，直方图上会亮出它到底改了哪一段。

现在一共有十三课，从直方图、曝光、曲线，到白平衡、光圈、焦距，还有视频的帧率和 Log。
文字和动画，都是我们自己写、自己画的，而且还在一课一课地往上加。

〔画面：互动课录屏：像素飞成直方图的动画；光圈滑块和虚化；五个亮度区随滑块亮起。〕

### 7. 名字（约 10 秒）

它叫 Lucet 光集。
Lucet 是拉丁语，意思是「它在发光」。
光集，是把光收集起来。
一张照片，本来就是被留住的光。

〔画面：图标，慢慢出现「让每一个瞬间，自有光彩。」〕

### 8. 诚实的话，和邀请（约 40 秒）

最后说几句实在的。

它现在还是早期版本：只能在 Apple 芯片的 Mac 上用，需要 macOS 15 以上，界面目前只有中文。还没有经过苹果的公证，第一次打开，要在系统设置里手动放行一次。

它不会改动你的原片，没有账号，也不会上传你的任何照片。

如果你也有一堆舍不得删、又不知道怎么调的照片，欢迎来试试。
哪里不顺手，哪里看不懂，都告诉我。
你要是也在用 AI 做自己的东西，也来聊聊，我们互相看看。

让每一个瞬间，自有光彩。

〔画面：官网和 GitHub 地址；最后回到开场那段你自己拍的素材，调好之后的版本。〕

---

## English version

*Written for an English-speaking audience, not a line-by-line translation. Note: the app's interface is Chinese only for now — the script says so, so nobody downloads it and feels misled.*

### 1. Cold open (~15 s)

I shot some footage I really loved.
I got home, opened my Mac, and wanted to do one simple thing: make the colours look right.
And then I ran into something strange.

[Your own drone or landscape shot, 2–3 seconds, no text. Then cut to you on camera.]

### 2. The problem (~35 s)

DJI's editing app, Mimo, only exists on phones.
So to grade on a big screen, I'd have to send everything back to my phone and nudge sliders on a tiny screen.

Fine — use the pro tools, then.
Lightroom and Photoshop can do anything.
But the first time you open them, you're staring at dozens of sliders.
Exposure, highlights, shadows, whites, blacks, dehaze…
I didn't know which one to touch first, or whether I'd just made it better or worse.

【Your honest feeling, in one line — e.g. "I just wanted a nice photo. I didn't want to take a course first."】

[A phone screen with tiny sliders; then a wall of sliders, blurred, no other brand's logo.]

### 3. So I built one (~50 s)

So I wondered: could there be a tool that's as simple as a phone app, but on the Mac —
and that, when you're curious, actually explains *why*?

The very first prototype was written by ChatGPT. It ran, but it was slow and messy.
Then I took it into Claude Code, and the first job wasn't adding features. It was finding problems — and measuring every one of them on my Mac.

Adding a folder with two thousand files used to take almost seven seconds and freeze the whole window. Now it's under a hundredth of a second.
DJI's own LUTs for the Pocket 3 wouldn't even import, because of how their titles were encoded. Now they just work.

[The first commit on GitHub: "Baseline: ChatGPT prototype as received". Then a big folder dropped into Lucet, thumbnails appearing instantly.]

### 4. One sentence, one change (~55 s)

The part that surprised me most:
almost every change started with one plain sentence from me.

"This blue is too bright."
"The right side feels loose."
"There isn't enough information here."
"Too many boxes."

I'd say it, the AI would try something, I'd look, and say the next thing. Round after round.

And yes — the AI gets things wrong, and it can sound very sure of itself.
It once looked at a latte on a white table and told me the photo was "too bright", and suggested pulling the exposure down by a stop and a half.
But a white table is *supposed* to be bright.
You only catch that kind of mistake by actually using the thing. So we fixed it, and added a test so it can't come back.

【One line on what working with AI felt like for you — e.g. "It's fast, but deciding what looks right is still my job."】

[Real before/after screenshots: the too-bright blue vs. the calm grey UI; the latte photo and the wrong tip.]

### 5. What it does today (~65 s)

So what can it actually do? Let me just show you.

Drag in a folder, or a few photos.
Press Auto. It reads this particular photo first, then fixes the light and colour.
It's restrained on purpose: a bright white scene stays bright, a night shot stays a night shot, a sunset keeps its warmth. Don't like it? Undo, and you're back.

If you want to adjust it yourself, there are just six sliders by default: brightness, contrast, highlights, shadows, warmth, and vibrance. Each one comes with a plain sentence about what it does.

Presets aren't a list of mysterious names — each one is a little preview made from *your* photo. Pick the one you like.
Cropping? Just drag on the photo.

When you're done, it saves straight into Photos on your Mac. With iCloud Photos on, it's on your iPhone a moment later.
And video clips under three seconds can become real Live Photos.

[All real screen recording: Auto with before/after; tapping preset thumbnails; dragging the crop frame; then an iPhone showing the photo in its library.]

### 6. Learning while you edit (~65 s)

But the thing I care about most is something else.

A one-tap filter can make a photo look better — and next time, you still don't know why.

There's a photography creator on Douyin, Zhang Xiaoyang, who explains histograms, curves and aperture with animation, more clearly than any manual I've read.
But he's only made a handful of videos. They can't cover all the basics.

So we brought that way of teaching into the app — using *your own* photos.
Watch your picture break into pixels and pile up by brightness into a little mountain: that's a histogram.
Drag the aperture and watch the background soften.
Drag "highlights", and the histogram lights up exactly the part it's changing.

There are thirteen lessons now — histograms, exposure, curves, white balance, aperture, focal length, even frame rate and Log footage for video.
Every word and every animation is our own, and we're still adding lessons one at a time.

[Lesson recordings: pixels flying into a histogram; the aperture slider and background blur; the five brightness zones lighting up.]

### 7. The name (~10 s)

It's called Lucet.
Lūcet is Latin for "it shines".
Its Chinese name, 光集, means "gathering light".
Because a photo is just that: light you decided to keep.

[The icon; then the line "Let your moments shine."]

### 8. Honestly, and an invitation (~55 s)

A few honest things before you go.

It's an early version. It runs on Apple-silicon Macs with macOS 15 or later, and right now the interface is in Chinese only. It isn't notarized by Apple yet, so the first time you open it, you'll need to allow it once in System Settings.

It never changes your originals. There's no account, and none of your photos are uploaded anywhere.

If you've got a folder of photos you can't bring yourself to delete, but don't know how to fix — come and try it.
Tell me where it's confusing, or where it gets in your way.
And if you're building your own thing with AI, tell me about it. I'd love to see what you're making.

Let your moments shine.

[Website and GitHub link; end on your opening shot again — this time, graded.]
