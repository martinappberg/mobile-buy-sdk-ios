//
//  BUYViewController.m
//  Mobile Buy SDK
//
//  Created by Joshua Tessier on 2015-02-11.
//  Copyright (c) 2015 Shopify Inc. All rights reserved.
//

@import AddressBook;
@import PassKit;
#import "BUYApplePayAdditions.h"
#import "BUYCart.h"
#import "BUYClient.h"
#import "BUYViewController.h"
#import "BUYApplePayHelpers.h"

@interface BUYViewController () <PKPaymentAuthorizationViewControllerDelegate>
@property (nonatomic, strong) BUYCheckout *checkout;
@property (nonatomic, strong) BUYApplePayHelpers *applePayHelper;
@end

@implementation BUYViewController

@synthesize client = _client;

- (instancetype)initWithClient:(BUYClient *)client
{
	self = [super init];
	if (self) {
		self.client = client;
	}
	return self;
}

- (void)setClient:(BUYClient *)client
{
	_client = client;
	self.merchantCapability = PKMerchantCapability3DS;
	self.supportedNetworks = @[PKPaymentNetworkAmex, PKPaymentNetworkMasterCard, PKPaymentNetworkVisa];
	self.countryCode = @"US";
	self.currencyCode = @"USD";
}

- (BUYClient*)client
{
	if (_client == nil) {
		NSLog(@"`BUYClient` has not been initialized. Please initialize BUYViewController with `initWithClient:` or set a `BUYClient` after Storyboard initialization");
	}
	return _client;
}

- (BOOL)isApplePayAvailable
{
	// checks if device hardware is capable of using Apple Pay
	// checks if the device has a payment card setup
	// checks if the client is setup to use Apple Pay
	return ([PKPaymentAuthorizationViewController canMakePayments] && [PKPaymentAuthorizationViewController canMakePaymentsUsingNetworks:self.supportedNetworks] && self.client.merchantId.length);
}

#pragma mark - Checkout Flow Methods
#pragma mark - Step 1 - Creating a Checkout

- (void)startApplePayCheckoutWithCart:(BUYCart *)cart
{
	[self.client createCheckout:[[BUYCheckout alloc] initWithCart:cart] completion:^(BUYCheckout *checkout, NSError *error) {
		
		self.applePayHelper = [[BUYApplePayHelpers alloc] initWithClient:self.client checkout:checkout];
		[self handleCheckoutCompletion:checkout error:error];
	}];
}

- (void)startWebCheckoutWithCart:(BUYCart *)cart
{
	BUYCheckout *checkout = [[BUYCheckout alloc] initWithCart:cart];
	[self.client createCheckout:checkout completion:^(BUYCheckout *checkout, NSError *error) {
		
		if (error == nil) {
			[[UIApplication sharedApplication] openURL:checkout.webCheckoutURL];
		}
		else {
			[self.delegate controller:self failedToCreateCheckout:error];
		}
	}];
	
}


#pragma  mark - Alternative Step 1 - Creating a Checkout using a Cart Token

- (void)startCheckoutWithCartToken:(NSString *)token
{
	[self.client createCheckoutWithCartToken:token completion:^(BUYCheckout *checkout, NSError *error) {
		self.applePayHelper = [[BUYApplePayHelpers alloc] initWithClient:self.client checkout:checkout];
		[self handleCheckoutCompletion:checkout error:error];
	}];
}

- (void)handleCheckoutCompletion:(BUYCheckout *)checkout error:(NSError *)error
{
	if (checkout && error == nil) {
		_checkout = checkout;
		[self requestPayment];
	}
	else {
		[_delegate controller:self failedToCreateCheckout:error];
	}
}

#pragma mark - Step 2 - Requesting Payment using ApplePay

- (void)requestPayment
{
	//Step 2 - Request payment from the user by presenting an Apple Pay sheet
	if (self.client.merchantId.length == 0) {
		NSLog(@"Merchant ID must be configured to use Apple Pay");
		[_delegate controllerFailedToStartApplePayProcess:self];
		return;
	}
	
	PKPaymentRequest *request = [self paymentRequest];
	request.paymentSummaryItems = [_checkout buy_summaryItems];
	PKPaymentAuthorizationViewController *controller = [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest:request];
	if (controller) {
		controller.delegate = self;
		[self presentViewController:controller animated:YES completion:nil];
	}
	else {
		[_delegate controllerFailedToStartApplePayProcess:self];
	}
}

- (void)checkoutCompleted:(BUYCheckout *)checkout status:(BUYStatus)status
{
	[_delegate controller:self didCompleteCheckout:checkout status:status];
}

#pragma mark - PKPaymentAuthorizationViewControllerDelegate Methods

- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller didAuthorizePayment:(PKPayment *)payment completion:(void (^)(PKPaymentAuthorizationStatus status))completion
{
	[self.applePayHelper updateAndCompleteCheckoutWithPayment:payment completion:^(PKPaymentAuthorizationStatus status) {
		
		switch (status) {
			case PKPaymentAuthorizationStatusFailure:
				[_delegate controller:self failedToCompleteCheckout:self.checkout withError:self.applePayHelper.lastError];
				break;
				
			case PKPaymentAuthorizationStatusInvalidShippingPostalAddress:
				[_delegate controller:self failedToUpdateCheckout:self.checkout withError:self.applePayHelper.lastError];
				break;

			default: {
				BUYStatus buyStatus = (status == PKPaymentAuthorizationStatusSuccess) ? BUYStatusComplete : BUYStatusFailed;
				[_delegate controller:self didCompleteCheckout:self.checkout status:buyStatus];
			}
				break;
		}

		completion(status);
	}];
}

- (void)paymentAuthorizationViewControllerDidFinish:(PKPaymentAuthorizationViewController *)controller
{
	// The checkout is done at this point, it may have succeeded or failed. You are responsible for dealing with failure/success earlier in the steps.
	[controller dismissViewControllerAnimated:YES completion:nil];
}

- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller didSelectShippingMethod:(PKShippingMethod *)shippingMethod completion:(void (^)(PKPaymentAuthorizationStatus status, NSArray *summaryItems))completion
{
	[self.applePayHelper updateCheckoutWithShippingMethod:shippingMethod completion:^(PKPaymentAuthorizationStatus status, NSArray *methods) {
		
		if (status == PKPaymentAuthorizationStatusInvalidShippingPostalAddress) {
			[_delegate controller:self failedToGetShippingRates:_checkout withError:self.applePayHelper.lastError];
		}
		
		completion(status, methods);
	}];
}

- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller didSelectShippingAddress:(ABRecordRef)address completion:(void (^)(PKPaymentAuthorizationStatus status, NSArray *shippingMethods, NSArray *summaryItems))completion
{
	[self.applePayHelper updateCheckoutWithAddress:address completion:^(PKPaymentAuthorizationStatus status, NSArray *shippingMethods, NSArray *summaryItems) {
		
		if (status == PKPaymentAuthorizationStatusInvalidShippingPostalAddress) {
			[_delegate controller:self failedToUpdateCheckout:self.checkout withError:self.applePayHelper.lastError];
		}
		completion(status, shippingMethods, summaryItems);
	}];
}

#pragma mark - Helpers

- (PKPaymentRequest *)paymentRequest
{
	PKPaymentRequest *paymentRequest = [[PKPaymentRequest alloc] init];
	[paymentRequest setMerchantIdentifier:self.client.merchantId];
	[paymentRequest setRequiredBillingAddressFields:PKAddressFieldAll];
	[paymentRequest setRequiredShippingAddressFields:_checkout.requiresShipping ? PKAddressFieldAll : PKAddressFieldEmail|PKAddressFieldPhone];
	[paymentRequest setSupportedNetworks:self.supportedNetworks];
	[paymentRequest setMerchantCapabilities:self.merchantCapability];
	[paymentRequest setCountryCode:self.countryCode];
	[paymentRequest setCurrencyCode:self.currencyCode];
	return paymentRequest;
}

@end
