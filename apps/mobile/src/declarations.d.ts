declare module 'react-native-razorpay' {
  interface RazorpayCheckoutOptions {
    description?: string;
    image?: string;
    currency: string;
    key: string;
    amount: string | number;
    name: string;
    order_id: string;
    prefill?: {
      email?: string;
      contact?: string;
      name?: string;
    };
    theme?: {
      color?: string;
    };
  }

  interface RazorpaySuccessResponse {
    razorpay_payment_id: string;
    razorpay_order_id: string;
    razorpay_signature: string;
  }

  interface RazorpayErrorResponse {
    code: number;
    description: string;
    reason?: string;
    step?: string;
    source?: string;
    metadata?: Record<string, unknown>;
  }

  export default class RazorpayCheckout {
    static open(
      options: RazorpayCheckoutOptions
    ): Promise<RazorpaySuccessResponse>;
  }
}
