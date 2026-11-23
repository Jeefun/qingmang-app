/**
 * 极薄的 HTTP 封装。内容源接口只需要 GET / POST + 自定义头 + 字符串响应，
 * 所以直接走 NetworkKit 的 http 模块，不引入额外依赖。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class HttpResponse {
  statusCode: number = 0;
  body: string = '';
}

export class HttpError extends Error {
  statusCode: number = 0;

  constructor(message: string, statusCode: number) {
    super(message);
    this.statusCode = statusCode;
  }
}

export class BufferResponse {
  statusCode: number = 0;
  data: ArrayBuffer = new ArrayBuffer(0);
}

/** 下载整段媒体：内容源单集约 8 MB，直接取二进制比流式落盘更简单可靠 */
export async function httpRequestBuffer(url: string, headers: Record<string, string>,
  timeoutMs: number = 60000): Promise<BufferResponse> {
  const client = http.createHttp();
  const options: http.HttpRequestOptions = {
    method: http.RequestMethod.GET,
    header: headers,
    expectDataType: http.HttpDataType.ARRAY_BUFFER,
    connectTimeout: 15000,
    readTimeout: timeoutMs,
    usingCache: false
  };

  try {
    const response = await client.request(url, options);
    const result = new BufferResponse();
    result.statusCode = response.responseCode;
    if (response.result instanceof ArrayBuffer) {
      result.data = response.result;
    }
    return result;
  } catch (error) {
    const err = error as BusinessError;
    throw new HttpError(`媒体下载失败（${err.code}）：${err.message}`, 0);
  } finally {
    client.destroy();
  }
}

export async function httpRequest(url: string, method: http.RequestMethod,
  headers: Record<string, string>, body: string | null, timeoutMs: number = 20000): Promise<HttpResponse> {
  const client = http.createHttp();
  const options: http.HttpRequestOptions = {
    method: method,
    header: headers,
    expectDataType: http.HttpDataType.STRING,
    connectTimeout: 15000,
    readTimeout: timeoutMs,
    usingCache: false
  };
  if (body !== null) {
    options.extraData = body;
  }

  try {
    const response = await client.request(url, options);
    const result = new HttpResponse();
    result.statusCode = response.responseCode;
    result.body = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
    return result;
  } catch (error) {
    const err = error as BusinessError;
    // 保留原始 code 与 message：2300999 这类通用码必须靠 message 才能定位
    throw new HttpError(`网络请求失败（${err.code}）：${err.message}`, 0);
  } finally {
    client.destroy();
  }
}
