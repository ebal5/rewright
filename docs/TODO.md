# rewright - MVP後のロードマップ

## Phase 1: Windows GUI (SuperWhisper代替の核)

- [ ] Win32システムトレイ常駐 (`Shell_NotifyIcon`)
- [ ] グローバルホットキー (`SetWindowsHookEx(WH_KEYBOARD_LL)`)
  - Push-to-Talk (KEY_DOWN/KEY_UP両方検知)
  - デフォルトキー: `Ctrl+Super` (OpenWhispr互換)
- [ ] ペーストシミュレーション (`SendInput` API で Ctrl+V)
  - クリップボード書き込み (`CF_UNICODETEXT`)
  - ペースト前に自ウィンドウからフォーカスを外す
  - ターミナル検出時は `Ctrl+Shift+V`
- [ ] フローティングオーバーレイウィンドウ
  - `WS_EX_TOPMOST`, `WS_EX_TOOLWINDOW`
  - 録音中インジケータ
  - ドラッグ移動

## Phase 2: 設定・UX改善

- [ ] 設定ファイル (JSON or TOML)
  - モデルパス、APIキー、ホットキー、言語設定
  - `~/.config/rewright/config.json`
  - 環境変数より設定ファイルを優先
- [ ] カスタム辞書 (OpenWhispr互換)
  - 専門用語・固有名詞の正確な書き起こし
  - Whisperのpromptパラメータに辞書を渡す
- [ ] 音声リテイン (録音データの保持)
  - 誤認識時の再推論用
  - 自動削除ポリシー (N日後)
- [ ] 文字起こし履歴 (SQLiteまたはファイルベース)
- [ ] 言語自動検出の改善
  - 日本語・英語の混在対応

## Phase 3: 推論の高速化・最適化

- [ ] ストリーミング推論 (リアルタイム部分結果)
  - whisper.cppの`new_segment_callback`活用
  - 長時間録音でも逐次テキスト表示
- [ ] VAD (Voice Activity Detection)
  - whisper.cpp内蔵VAD (`whisper_vad_*` API)
  - 無音区間の自動スキップで推論高速化
- [ ] モデル事前ロード (ウォームアップ)
  - アプリ起動時にモデルをロードしておく
  - 初回推論のレイテンシ削減
- [ ] バイナリサイズ最適化
  - ReleaseSafe/ReleaseSmall ビルド
  - 不要なggmlバックエンドの除外

## Phase 4: GPU/NPU対応の深化

- [ ] Vulkanバックエンドの完全統合
  - SPIRVシェーダーのZigビルドシステム統合
  - Radeon 890M (iGPU) での動作確認
- [ ] CUDAバックエンドの完全統合
  - nvcc呼び出しのZigビルドシステム統合
  - RTX 3060 での動作確認
- [ ] AMD Ryzen AI NPU対応 (将来)
  - AMDフォーク版whisper.cpp (`github.com/amd/whisper.cpp`) の調査
  - Windows限定、base/small/mediumモデルまで

## Phase 5: LLM連携の強化

- [ ] エージェントモード (OpenWhispr互換)
  - 名前で呼びかけるとコマンド実行
  - `fullPrompt`テンプレートの移植 (MODE 1: CLEANUP + MODE 2: AGENT)
- [ ] Anthropic API直接対応
  - `X-API-Key` + `anthropic-version` ヘッダー
  - `/v1/messages` エンドポイント
- [ ] ストリーミングLLMレスポンス
  - SSEパーサー
  - 逐次テキスト表示
- [ ] プロンプトのカスタマイズ
  - 設定ファイルでシステムプロンプト変更可能

## Phase 6: クロスプラットフォーム

- [ ] Linux GUI
  - Wayland対応 (wlr-layer-shell)
  - D-Busグローバルショートカット
  - `wtype`/`xdotool`でのペースト
- [ ] macOS対応 (低優先)
  - Metal/CoreMLバックエンド
  - CoreAudioキャプチャ

## 既知の技術的負債

- [ ] 静的バッファの非スレッドセーフ性 (whisper.zig, wav.zig)
  - 将来のGUI化でマルチスレッド必須時に要対応
  - アロケータベースに切り替え
- [ ] `AudioSegment.len`フィールドの冗長性 (`data.len`で代替可)
- [ ] `deprecatedWriter()`/`deprecatedReader()` → Zig 0.15の新APIに移行
- [ ] LLM hookの`timeout_ms`未使用 (std.http.Clientの制限)
- [ ] テスト二重実行 (build.zigのwav_mod + test_wav.zig)

## 参考情報

- OpenWhispr原本: https://github.com/OpenWhispr/openwhispr
- 原本のプロンプト資産: `prompts/cleanup.json` に移植済み
- 原本のフルプロンプト (エージェントモード): `openwhispr-original/src/locales/en/prompts.json`
- whisper.cpp: https://github.com/ggerganov/whisper.cpp
- ハードウェア調査結果: `docs/superpowers/plans/2026-03-26-zig-whisper-mvp.md`内に記録

## ターゲットハードウェア

1. AMD Ryzen AI 9 HX 370 + Radeon 890M → Vulkan (or NPU将来)
2. Ryzen 7700 + RTX 3060 → CUDA
