///
/// Auto-generated by Stone, do not modify.
///

/// Routes for the users namespace
public class UsersRoutes {
    public let client: DropboxTransportClient
    init(client: DropboxTransportClient) {
        self.client = client
    }

    /// Get information about a user's account.
    ///
    /// - parameter accountId: A user's account identifier.
    ///
    ///  - returns: Through the response callback, the caller will receive a `Users.BasicAccount` object on success or a
    /// `Users.GetAccountError` object on failure.
    public func getAccount(accountId: String) -> RpcRequest<Users.BasicAccountSerializer, Users.GetAccountErrorSerializer> {
        let route = Users.getAccount
        let serverArgs = Users.GetAccountArg(accountId: accountId)
        return client.request(route: route, serverArgs: serverArgs)
    }

    /// Get information about multiple user accounts.  At most 300 accounts may be queried per request.
    ///
    /// - parameter accountIds: List of user account identifiers.  Should not contain any duplicate account IDs.
    ///
    ///  - returns: Through the response callback, the caller will receive a `Array<Users.BasicAccount>` object on
    /// success or a `Users.GetAccountBatchError` object on failure.
    public func getAccountBatch(accountIds: Array<String>) -> RpcRequest<ArraySerializer<Users.BasicAccountSerializer>, Users.GetAccountBatchErrorSerializer> {
        let route = Users.getAccountBatch
        let serverArgs = Users.GetAccountBatchArg(accountIds: accountIds)
        return client.request(route: route, serverArgs: serverArgs)
    }

    /// Get information about the current user's account.
    ///
    ///
    ///  - returns: Through the response callback, the caller will receive a `Users.FullAccount` object on success or a
    /// `Void` object on failure.
    public func getCurrentAccount() -> RpcRequest<Users.FullAccountSerializer, VoidSerializer> {
        let route = Users.getCurrentAccount
        return client.request(route: route)
    }

    /// Get the space usage information for the current user's account.
    ///
    ///
    ///  - returns: Through the response callback, the caller will receive a `Users.SpaceUsage` object on success or a
    /// `Void` object on failure.
    public func getSpaceUsage() -> RpcRequest<Users.SpaceUsageSerializer, VoidSerializer> {
        let route = Users.getSpaceUsage
        return client.request(route: route)
    }

}
