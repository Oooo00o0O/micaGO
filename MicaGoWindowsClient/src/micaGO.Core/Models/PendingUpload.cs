namespace MicaGo.Core.Models;

public sealed record PendingUpload(string TempId,string ChatId,string FilePath,string FileName,string MimeType,long Size,long DateCreated,string State="sending",string? Error=null)
{
    public Message ToMessage() => new(TempId,ChatId,"",DateTimeOffset.FromUnixTimeMilliseconds(DateCreated).LocalDateTime.ToString("HH:mm"),true,
        State=="failed"?MessageDeliveryState.Failed:State=="sent_unconfirmed"?MessageDeliveryState.Sent:MessageDeliveryState.AwaitingConfirmation,
        AttachmentLabel:FileName,DateCreated:DateCreated,Attachments:[new Attachment(TempId,FileName,MimeType,Size)],IsPending:true,ErrorText:Error,PresentationId:TempId);
}
