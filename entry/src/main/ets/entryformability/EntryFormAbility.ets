/**
 * 桌面卡片 FormExtensionAbility：
 * onAddForm 把初始数据绑给卡片并登记 formId；
 * 播放进度变化由 CardSync.pushUpdate 主动推送。
 */
import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { CardSync } from '../store/CardSync';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    let formId = '';
    const identity = want.parameters?.['ohos.extra.param.key.form_identity'];
    if (typeof identity === 'string') {
      formId = identity;
    }
    if (formId.length > 0) {
      CardSync.rememberFormId(formId);
    }
    return formBindingData.createFormBindingData(CardSync.cardData());
  }

  onCastToNormalForm(formId: string): void {
    // 临时卡片转常态卡片：formId 不变，无需处理
  }

  onUpdateForm(formId: string): void {
    try {
      formProvider.updateForm(formId, formBindingData.createFormBindingData(CardSync.cardData()));
    } catch (error) {
      // 卡片已失效，忽略
    }
  }

  onRemoveForm(formId: string): void {
    CardSync.forgetFormId(formId);
  }
}
