/**
 * 「继续观看」桌面卡片。
 *
 * 数据由 EntryFormAbility 通过 formBindingData 注入 LocalStorage；
 * 点击整卡用 postCardAction router 拉起 EntryAbility，并把
 * seriesId/episodeIndex 带过去，由 Index 解析后直接进播放页。
 * 卡片不支持网络图片，封面位置用渐变底 + 播放图形代替。
 */
let storage = new LocalStorage();

@Entry(storage)
@Component
struct ContinueCard {
  @LocalStorageProp('title') title: string = '打开青芒，开始追剧';
  @LocalStorageProp('sub') sub: string = '看过的剧会出现在这里';
  @LocalStorageProp('seriesId') seriesId: string = '';
  @LocalStorageProp('episodeIndex') episodeIndex: number = 0;

  build() {
    Column() {
      Row({ space: 8 }) {
        // 播放图形：圆底 + 三角
        Stack() {
          Circle({ width: 28, height: 28 })
            .fill('#33FFFFFF')
          Text('▶')
            .fontSize(12)
            .fontColor(Color.White)
            .textAlign(TextAlign.Center)
            .width(28)
            .height(28)
        }
        .width(28)
        .height(28)

        Text('青芒续播')
          .fontSize(11)
          .fontColor('#99FFFFFF')
          .maxLines(1)
          .layoutWeight(1)
      }
      .width('100%')

      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.sub)
          .fontSize(11)
          .fontColor('#B3FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .padding(12)
    .width('100%')
    .height('100%')
    .borderRadius(16)
    .linearGradient({
      angle: 135,
      colors: [['#FF2E5E4B', 0], ['#FF141C16', 1]]
    })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.SpaceBetween)
    .onClick(() => {
      postCardAction(this, {
        'action': 'router',
        'abilityName': 'EntryAbility',
        'params': {
          'seriesId': this.seriesId,
          'episodeIndex': this.episodeIndex
        }
      });
    })
  }
}
