# AI Passport 固件实施前调研

## 已确认的边界

- 官方仓库提供完整硬件测试工程，可复用 BSP，不是现成语音面板；衍生应用需要独立界面。开发基线为 ESP-IDF 5.5.3，硬件为 ESP32-C3、8 MB Flash、无 PSRAM、240×320 三键设备。[官方工程](https://github.com/FoloToy/ai-passport)、[构建环境](https://github.com/FoloToy/ai-passport/blob/main/docs/development/engineering/environment-setup.md)
- 官方主分支的 Wi-Fi 示例只扫描，不连接、不保存网络；独立面板需实现配网及凭证管理。不能假设安装独立固件后仍保留原固件的手机配网页面。[Wi-Fi 示例](https://github.com/FoloToy/ai-passport/blob/main/main/demo_wifi.c)、[配网参考](https://github.com/FoloToy/ai-passport/blob/main/docs/development/engineering/wifi-provisioning.md)
- 社区语音项目为 MIT 许可的功能模块，不是可直接刷写的完整工程；现有 UDP 协议没有配对鉴权或输入目标概念，不能原样用于正式版本。[社区工程](https://github.com/manchunx7-bit/folo-ai-passport-voice)、[移植边界](https://github.com/manchunx7-bit/folo-ai-passport-voice/blob/main/docs/PORTING.zh-CN.md)、[UDP 实现](https://github.com/manchunx7-bit/folo-ai-passport-voice/blob/main/device/main/apps/voice/udp_audio.c)
- 官方默认分区没有 OTA 回滚槽；合并镜像从 0x0 写入，可能重置 NVS 配置。不得将开发、编译授权解释为刷写授权。[固件布局](https://github.com/FoloToy/ai-passport/blob/main/docs/development/engineering/firmware-layout.md)
- 官方原厂恢复流程依赖设备背面二维码中的专属链接及在线服务；不能承诺离线回滚或公开通用恢复镜像。专属链接中的 SN/KEY 不得进入仓库或日志。[官方恢复流程](https://ai-passport.folotoy.cn/guides/restore-factory-firmware/)

## 本项目已确认的方向

用户选择独立语音控制面板，不要求保留其他原有应用。设备型号未知，先按上述标准硬件开发；实物型号、Flash 容量和恢复方式未经核验前不刷写，也不声明实机兼容。

## 证据限制

以上为公开文档与源码调研，不是设备实测；未执行固件构建、刷写、恢复或无线音频验收。
